# frozen_string_literal: true

require "test_helper"

# Editing a scenario catalog in the dashboard (an empty catalog, then its
# products, sets and scenarios one at a time), exporting a selection of it,
# and previewing an import before it is applied, in replace and merge mode.
class ScenarioCatalogEntriesApiTest < ActionDispatch::IntegrationTest
  BASE = "/activeagents/api/scenario_catalogs"

  DOCUMENT = <<~YAML
    catalog: checkout
    name: Checkout
    products:
      - key: cart
        name: Cart agent
        sets:
          - key: uat
            name: UAT
            scenarios:
              - key: add_item
                prompt: Add two of item 7 to the cart.
              - key: remove_item
                prompt: Remove item 7 from the cart.
          - key: smoke
            scenarios:
              - key: empty
                prompt: Empty the cart.
  YAML

  def setup
    ActionAgent::ScenarioCatalog.delete_all
    ActionAgent::Agent.delete_all
    ActionAgent.active_storage = :auto
    @agent = ActionAgent::Agent.create!(name: "Cart", provider: "mock", model: "mock", instructions: "Manage the cart.")
  end

  def teardown
    ActionAgent.active_storage = :auto
    ActionAgent.permission_checker = nil
  end

  def body
    JSON.parse(response.body)
  end

  def import!(document = DOCUMENT, **extra)
    post BASE, params: { document: document }.merge(extra), as: :json
    assert_response :created, response.body
    ActionAgent::ScenarioCatalog.find(body["catalogs"].sole["id"])
  end

  test "builds a catalog entry by entry, keeping its document and digest current" do
    post BASE, params: { catalog: { name: "Support desk" } }, as: :json
    assert_response :created, response.body
    catalog = body["catalogs"].sole
    assert_equal [ "support_desk", "api", 0 ], catalog.values_at("key", "source_kind", "scenario_count")
    id = catalog["id"]

    post "#{BASE}/#{id}/products", params: { product: { name: "Triage", agent_id: @agent.id } }, as: :json
    assert_response :created, response.body
    product = body["product"]
    assert_equal [ "triage", "Cart" ], [ product["key"], product.dig("agent", "name") ]

    post "#{BASE}/#{id}/products/#{product['id']}/sets", params: { set: { name: "Smoke", judge: { kind: "rules" } } }, as: :json
    assert_response :created, response.body
    set = body["set"]
    assert_equal "smoke", set["key"]

    post "#{BASE}/#{id}/sets/#{set['id']}/scenarios",
      params: { scenario: { prompt: "A customer asks for a refund", notes: "Looks the order up first.",
                            expect: { tools: "lookup_order, refund_order", contains: [ "refund" ] }, tags: "billing" } }, as: :json
    assert_response :created, response.body
    scenario = body["scenario"]
    assert_equal "a_customer_asks_for_a_refund", scenario["key"]
    assert_equal({ "tools" => %w[lookup_order refund_order], "contains" => [ "refund" ] }, scenario["expectations"])
    assert_equal [ "billing" ], scenario["tags"]

    record = ActionAgent::ScenarioCatalog.find(id)
    digest = record.digest
    assert_includes record.document, "A customer asks for a refund"

    patch "#{BASE}/#{id}/sets/#{set['id']}/scenarios/#{scenario['id']}", params: { scenario: { prompt: "Refund order A-17", key: "" } }, as: :json
    assert_response :success, response.body
    assert_equal [ "a_customer_asks_for_a_refund", "Refund order A-17" ], body["scenario"].values_at("key", "prompt")
    assert_not_equal digest, record.reload.digest
    assert_includes record.document, "Refund order A-17"

    delete "#{BASE}/#{id}/sets/#{set['id']}/scenarios/#{scenario['id']}", as: :json
    assert_response :success
    assert_equal 0, body.dig("catalog", "scenario_count")
  end

  test "an entry the importer would refuse is refused, and nothing changes" do
    catalog = import!
    product = catalog.products.sole

    post "#{BASE}/#{catalog.id}/products", params: { product: { key: "-bad key", name: "Bad" } }, as: :json
    assert_response :unprocessable_entity
    assert_match(/Key/, body["errors"].join)

    set = product.sets.find_by!(key: "uat")
    post "#{BASE}/#{catalog.id}/sets/#{set.id}/scenarios", params: { scenario: { key: "add_item", prompt: "Again" } }, as: :json
    assert_response :unprocessable_entity
    assert_equal 2, set.scenarios.count

    ActionAgent.permission_checker = ->(_user, action, _subject) { action != :replace_scenarios }
    delete "#{BASE}/#{catalog.id}/sets/#{set.id}", as: :json
    assert_response :forbidden
    assert ActionAgent::ScenarioSet.exists?(set.id)
  end

  test "exports a set or chosen scenarios, which a merge import reads back without dropping the rest" do
    catalog = import!
    uat = catalog.sets.find_by!(key: "uat")
    remove = uat.scenarios.find_by!(key: "remove_item")

    get "#{BASE}/#{catalog.id}/export", params: { set_ids: uat.id.to_s, disposition: "inline" }
    assert_response :success
    exported = YAML.safe_load(response.body)
    assert_equal [ "uat" ], exported.dig("products", 0, "sets").map { |set| set["key"] }

    get "#{BASE}/#{catalog.id}/export", params: { scenario_ids: [ remove.id ] }
    assert_response :success
    assert_match(/checkout-selection\.yml/, response.headers["Content-Disposition"])
    exported = YAML.safe_load(response.body)
    assert_equal [ "remove_item" ], exported.dig("products", 0, "sets", 0, "scenarios").map { |scenario| scenario["key"] }

    exported["products"][0]["sets"][0]["scenarios"][0]["prompt"] = "Remove every item 7."
    post BASE, params: { document: YAML.dump(exported), mode: "merge" }, as: :json
    assert_response :created, response.body
    catalog.reload
    assert_equal 3, catalog.scenario_count
    assert_equal "Remove every item 7.", remove.reload.prompt
    assert_includes catalog.document, "Remove every item 7."
  end

  test "previews an import by key before applying it, in replace and merge mode" do
    import!
    changed = <<~YAML
      catalog: checkout
      name: Checkout
      products:
        - key: cart
          name: Cart agent
          sets:
            - key: uat
              name: UAT
              scenarios:
                - key: add_item
                  prompt: Add two of item 7 to the cart.
                - key: remove_item
                  prompt: Remove item 8.
                - key: checkout
                  prompt: Check out.
    YAML

    post "#{BASE}/preview", params: { document: changed }, as: :json
    assert_response :success, response.body
    preview = body["previews"].sole
    assert_equal [ "unchanged", "replace", 3 ], [ preview.dig("catalog", "action"), preview["mode"], preview["scenario_count"] ]
    actions = preview["changes"].to_h { |change| [ change["path"], change["action"] ] }
    assert_equal "update", actions["cart/uat/remove_item"]
    assert_equal "create", actions["cart/uat/checkout"]
    assert_equal "remove", actions["cart/smoke"]
    assert_nil actions["cart/uat/add_item"]

    post "#{BASE}/preview", params: { document: changed, mode: "merge" }, as: :json
    actions = body["previews"].sole["changes"].to_h { |change| [ change["path"], change["action"] ] }
    assert_equal "keep", actions["cart/smoke"]

    assert_equal 3, ActionAgent::ScenarioCatalog.sole.scenario_count, "a preview writes nothing"

    post BASE, params: { document: "products: [" }, as: :json
    assert_response :unprocessable_entity
    post "#{BASE}/preview", params: { document: "catalog: x", mode: "sideways" }, as: :json
    assert_response :unprocessable_entity
  end
end
