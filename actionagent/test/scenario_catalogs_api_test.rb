# frozen_string_literal: true

require "test_helper"

# The catalogs API: import from a document or a connected repository, read,
# export as YAML, sync with Active Storage, and run a set against an agent.
class ScenarioCatalogsApiTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  DOCUMENT = <<~YAML
    catalog: checkout
    name: Checkout
    products:
      - key: cart
        name: Cart agent
        agent: Cart
        sets:
          - key: uat
            name: UAT
            scenarios:
              - key: add_item
                prompt: Add two of item 7 to the cart.
                expect:
                  tools: [add_to_cart]
              - key: remove_item
                prompt: Remove item 7 from the cart.
  YAML

  # Answers the GitHub contents API for one repository at one ref.
  class FakeGithub
    def initialize(files)
      @files = files
    end

    def repository(_full_name)
      { "default_branch" => "main" }
    end

    def tree(_full_name, ref:)
      { paths: @files.keys.map { |path| { path: path, size: 10 } }, truncated: false }
    end

    def file(_full_name, path, ref: nil)
      @files[path]
    end
  end

  def setup
    ActionAgent::ScenarioCatalog.delete_all
    ActionAgent::Evaluation.delete_all
    ActionAgent::Agent.delete_all
    ActionAgent::GithubConnection.delete_all
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

  test "imports a document, lists and shows the catalog, and exports its YAML" do
    post "/activeagents/api/scenario_catalogs", params: { document: DOCUMENT }, as: :json
    assert_response :created
    catalog = body["catalogs"].sole
    assert_equal "checkout", catalog["key"]
    assert_equal "cart", catalog.dig("products", 0, "key")
    assert_equal @agent.id, catalog.dig("products", 0, "agent", "id")
    assert_equal %w[add_item remove_item], catalog.dig("products", 0, "sets", 0, "scenarios").map { |scenario| scenario["key"] }

    get "/activeagents/api/scenario_catalogs"
    assert_response :success
    assert_equal [ "checkout" ], body["catalogs"].map { |entry| entry["key"] }
    assert_equal 2, body["catalogs"].first["scenario_count"]
    assert body["storage_available"]

    get "/activeagents/api/scenario_catalogs/#{catalog['id']}"
    assert_response :success
    assert_equal "Checkout", body.dig("catalog", "name")

    get "/activeagents/api/scenario_catalogs/#{catalog['id']}/export"
    assert_response :success
    assert_equal "application/x-yaml", response.media_type
    assert_match(/attachment; filename="checkout.yml"/, response.headers["Content-Disposition"])
    assert_includes response.body, "key: add_item"
  end

  test "an invalid document is refused with the reason" do
    post "/activeagents/api/scenario_catalogs", params: { document: "catalog: x\nproducts: [{ name: nameless }]" }, as: :json

    assert_response :unprocessable_entity
    assert_match(/product has no key/, body["errors"].first)
  end

  test "imports every catalog file of a connected repository at a ref" do
    ActionAgent::GithubConnection.create!(
      access_token: "gho_test", github_user_id: 42, login: "octocat",
      repositories: [ { "id" => 2, "full_name" => "acme/shop", "private" => true, "default_branch" => "main" } ]
    )
    files = {
      ".activeagents/evals/checkout.yml" => DOCUMENT,
      ".activeagents/evals/returns.yml" => "suite: returns\ngroups:\n  - key: refunds\n    scenarios:\n      - key: r1\n        prompt: Refund order 9.\n",
      ".activeagents/evals/nested/ignored.yml" => DOCUMENT,
      "README.md" => "# Shop"
    }

    ActionAgent::GithubClient.stub(:new, FakeGithub.new(files)) do
      post "/activeagents/api/scenario_catalogs", params: { repository: "acme/shop", ref: "feature/uat-31912" }, as: :json
    end

    assert_response :created
    catalogs = body["catalogs"]
    assert_equal %w[checkout returns], catalogs.map { |entry| entry["key"] }.sort
    assert_equal "repository", catalogs.first["source_kind"]
    assert_equal "acme/shop@feature/uat-31912:.activeagents/evals/checkout.yml",
      catalogs.find { |entry| entry["key"] == "checkout" }["source_path"]
    assert_equal [ "refunds" ], catalogs.find { |entry| entry["key"] == "returns" }.dig("products", 0, "sets").map { |set| set["key"] }
  end

  test "a repository import needs a GitHub connection" do
    post "/activeagents/api/scenario_catalogs", params: { repository: "acme/shop" }, as: :json

    assert_response :unprocessable_entity
    assert_equal "no_github_connection", body["code"]
  end

  test "sync writes to and restores from Active Storage, and says when storage is off" do
    post "/activeagents/api/scenario_catalogs", params: { document: DOCUMENT }, as: :json
    id = body["catalogs"].sole["id"]
    catalog = ActionAgent::ScenarioCatalog.find(id)
    assert catalog.synced?

    catalog.scenarios.destroy_all
    post "/activeagents/api/scenario_catalogs/#{id}/sync", params: { direction: "pull" }, as: :json
    assert_response :success
    assert_equal 2, body.dig("catalog", "scenario_count")

    ActionAgent.active_storage = false
    post "/activeagents/api/scenario_catalogs/#{id}/sync", as: :json
    assert_response :unprocessable_entity
    assert_equal "no_storage", body["code"]
  end

  test "running a set materializes the evaluation and queues the run" do
    post "/activeagents/api/scenario_catalogs", params: { document: DOCUMENT }, as: :json
    catalog = body["catalogs"].sole
    set_id = catalog.dig("products", 0, "sets", 0, "id")

    assert_enqueued_with(job: ActionAgent::EvaluationRunJob) do
      post "/activeagents/api/scenario_catalogs/#{catalog['id']}/sets/#{set_id}/run", params: { models: [ "mock/alpha" ] }, as: :json
    end

    assert_response :accepted
    assert_equal "pending", body.dig("run", "status")
    assert_equal "checkout/cart/uat", body.dig("evaluation", "name")
    evaluation = ActionAgent::Evaluation.find(body.dig("evaluation", "id"))
    assert_equal %w[add_item remove_item], evaluation.scenarios.ordered.pluck(:key)
    assert_equal set_id, body.dig("set", "evaluation", "id") && evaluation.config.dig("catalog", "set_id")
  end

  test "a set whose product names no agent asks for one" do
    post "/activeagents/api/scenario_catalogs", params: { document: DOCUMENT.sub("    agent: Cart\n", "") }, as: :json
    catalog = body["catalogs"].sole
    set_id = catalog.dig("products", 0, "sets", 0, "id")

    post "/activeagents/api/scenario_catalogs/#{catalog['id']}/sets/#{set_id}/run", as: :json
    assert_response :unprocessable_entity
    assert_equal "no_target", body["code"]

    post "/activeagents/api/scenario_catalogs/#{catalog['id']}/sets/#{set_id}/materialize", params: { agent_id: @agent.id }, as: :json
    assert_response :success
    assert_equal "checkout/cart/uat", body.dig("evaluation", "name")
  end

  test "importing and running need the replace_scenarios permission" do
    ActionAgent.permission_checker = ->(_user, action, _subject) { action != :replace_scenarios }

    post "/activeagents/api/scenario_catalogs", params: { document: DOCUMENT }, as: :json
    assert_response :forbidden
    assert_equal "replace_scenarios", body["permission"]
    assert_equal 0, ActionAgent::ScenarioCatalog.count
  end

  test "deleting a catalog keeps the evaluation a set became" do
    post "/activeagents/api/scenario_catalogs", params: { document: DOCUMENT }, as: :json
    catalog = body["catalogs"].sole
    set_id = catalog.dig("products", 0, "sets", 0, "id")
    post "/activeagents/api/scenario_catalogs/#{catalog['id']}/sets/#{set_id}/materialize", as: :json
    evaluation_id = body.dig("evaluation", "id")

    delete "/activeagents/api/scenario_catalogs/#{catalog['id']}"

    assert_response :no_content
    assert ActionAgent::Evaluation.exists?(evaluation_id)
    assert_equal 0, ActionAgent::ScenarioCatalog.count
  end
end
