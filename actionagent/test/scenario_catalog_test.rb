# frozen_string_literal: true

require "test_helper"

# Scenario catalogs: a YAML catalog imported into products, sets and
# scenarios, exported back as the same document, written to Active Storage
# when the engine has it, and run one set at a time as an evaluation of the
# agent under test.
class ScenarioCatalogTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  DOCUMENT = <<~YAML
    catalog: support_desk
    name: Support Desk
    description: What the support agents handle
    products:
      - key: triage
        name: Triage agent
        agent: Triage
        sets:
          - key: smoke
            name: Smoke
            judge:
              kind: rules
            scenarios:
              - key: refund_request
                prompt: A customer asks for a refund on order 1042.
                expect:
                  tools: [lookup_order]
                  contains: [refund]
                notes: Looks the order up first.
                tags: [billing]
                params:
                  locale: en
              - key: angry_customer
                prompt: Nobody answers my emails!
                expect:
                  not_contains: [unfortunately]
          - key: production
            name: Production data
            scenarios:
              - key: open_tickets
                prompt: Which open tickets mention a refund?
                production_only: true
  YAML

  def setup
    ActionAgent::ScenarioCatalog.delete_all
    ActionAgent::Evaluation.delete_all
    ActionAgent::Agent.delete_all
    ActionAgent.active_storage = :auto
    @agent = ActionAgent::Agent.create!(name: "Triage", provider: "mock", model: "mock", instructions: "Help the customer.")
  end

  def teardown
    ActionAgent.active_storage = :auto
  end

  def import(document = DOCUMENT, **options)
    ActionAgent::ScenarioCatalogImport.new(owner: nil, document: document, agents: ActionAgent::Agent.all, **options).call
  end

  test "imports products, sets and scenarios, resolving a product's agent by name" do
    catalog = import

    assert_equal "support_desk", catalog.key
    assert_equal "Support Desk", catalog.name
    assert_equal "upload", catalog.source_kind
    assert_equal %w[triage], catalog.products.map(&:key)
    product = catalog.products.first
    assert_equal @agent, product.agent
    assert_equal "Triage", product.agent_name
    assert_equal %w[smoke production], product.sets.map(&:key)
    smoke = product.sets.first
    assert_equal({ "kind" => "rules" }, smoke.judge)
    refund = smoke.scenarios.first
    assert_equal({ "tools" => [ "lookup_order" ], "contains" => [ "refund" ] }, refund.expectations)
    assert_equal [ "billing" ], refund.tags
    assert_equal({ "locale" => "en" }, refund.params)
    assert product.sets.last.scenarios.first.production_only?
    assert_equal 3, catalog.scenario_count
    assert_equal ActiveAgent::Evals::Catalog.parse(DOCUMENT).digest, catalog.digest
  end

  test "importing the same document again changes nothing, and a changed one replaces by key" do
    catalog = import
    ids = catalog.scenarios.order(:id).pluck(:id)
    digest = catalog.digest

    import
    assert_equal 1, ActionAgent::ScenarioCatalog.count
    assert_equal ids, catalog.reload.scenarios.order(:id).pluck(:id)
    assert_equal digest, catalog.digest

    changed = DOCUMENT.sub("order 1042", "order 2042").sub(/^ {10}- key: angry_customer\n.*?\n(?=^ {6}- key: production)/m, "")
    assert_not_includes changed, "angry_customer"
    import(changed)
    catalog.reload
    assert_not_equal digest, catalog.digest
    smoke = catalog.products.first.sets.find_by(key: "smoke")
    assert_equal %w[refund_request], smoke.scenarios.map(&:key)
    assert_equal ids.first, smoke.scenarios.first.id, "a kept scenario keeps its record"
    assert_match(/2042/, smoke.scenarios.first.prompt)
  end

  test "exports the canonical document, which imports back to the same digest" do
    catalog = import
    yaml = catalog.export_yaml

    assert_includes yaml, "catalog: support_desk"
    assert_includes yaml, "key: refund_request"
    assert_equal catalog.digest, ActiveAgent::Evals::Catalog.parse(yaml).digest
  end

  test "writes the document to Active Storage once per digest, and restores from it" do
    catalog = import

    assert ActionAgent::ScenarioCatalog.attachments_available?
    assert catalog.synced?
    assert catalog.document_file.attached?
    assert_equal "support_desk.yml", catalog.document_file.filename.to_s
    blob_id = catalog.document_file.blob_id

    assert catalog.sync_to_storage!
    assert_equal blob_id, catalog.reload.document_file.blob_id, "the same digest is not written again"

    catalog.scenarios.destroy_all
    assert_equal 0, catalog.scenario_count
    catalog.restore_from_storage!
    assert_equal 3, catalog.reload.scenario_count
  end

  test "without Active Storage the catalog lives in the database alone" do
    ActionAgent.active_storage = false
    catalog = import

    assert_not ActionAgent::ScenarioCatalog.attachments_available?
    assert_not catalog.synced?
    assert_not catalog.sync_to_storage!
    assert_nil catalog.synced_at
    assert_equal 3, catalog.scenario_count
  end

  test "refuses a document that is not a catalog, or over the limits" do
    assert_raises(ActionAgent::ScenarioCatalogImport::Invalid) { import("- a\n- list\n") }
    assert_raises(ActionAgent::ScenarioCatalogImport::Invalid) { import("catalog: x\nproducts: [{ key: p, sets: [{ key: s, scenarios: [{ key: k }] }] }]") }
    error = assert_raises(ActionAgent::ScenarioCatalogImport::Invalid) { import("catalog: big\n" + ("#" * ActionAgent::ScenarioCatalog::MAX_BYTES)) }
    assert_match(/larger than/, error.message)
    assert_equal 0, ActionAgent::ScenarioCatalog.count
  end

  test "a set materializes as an evaluation of the agent, named by its keys, with its scenarios and judge" do
    set = import.products.first.sets.first

    evaluation = set.materialize!

    assert_equal "support_desk/triage/smoke", evaluation.name
    assert_equal @agent, evaluation.agent
    assert_equal "rules", evaluation.judge_kind
    assert_equal %w[refund_request angry_customer], evaluation.scenarios.ordered.pluck(:key)
    assert_equal %w[smoke smoke], evaluation.scenarios.ordered.pluck(:group)
    assert_equal({ "tools" => [ "lookup_order" ], "contains" => [ "refund" ] }, evaluation.scenarios.ordered.first.expectations)
    assert_equal set.id, evaluation.config.dig("catalog", "set_id")
    assert_equal set.catalog.digest, evaluation.config.dig("catalog", "digest")
    assert_equal evaluation, set.reload.evaluation

    # Materializing again refreshes the same evaluation; a dropped scenario
    # is disabled, not destroyed, so earlier results still resolve.
    set.scenarios.find_by(key: "angry_customer").destroy!
    again = set.reload.materialize!
    assert_equal evaluation, again
    assert_equal 1, ActionAgent::Evaluation.where(agent: @agent).count
    assert_equal [ true, false ], again.scenarios.ordered.pluck(:enabled)
  end

  test "a set without an agent to run against says so" do
    document = DOCUMENT.sub("    agent: Triage\n", "")
    assert_not_includes document, "agent: Triage"
    set = import(document).products.first.sets.first

    assert_nil set.product.target_agent
    error = assert_raises(ActionAgent::ScenarioSet::NoAgent) { set.materialize! }
    assert_match(/Choose the agent/, error.message)
    assert_equal set.materialize!(agent: @agent).agent, @agent
  end

  test "running a set queues the evaluation run with the catalog reference in its selection" do
    set = import.products.first.sets.first

    run = nil
    assert_enqueued_with(job: ActionAgent::EvaluationRunJob) { run = set.run!(models: [ "mock/alpha" ]) }

    assert run.pending?
    assert_equal set.evaluation, run.evaluation
    assert_equal "support_desk", run.selection.dig("catalog", "catalog_key")
    assert_equal "smoke", run.selection.dig("catalog", "set_key")
    assert_equal [ "mock/alpha" ], run.selection["models"]
  end

  test "destroying a catalog keeps the evaluations its sets became" do
    catalog = import
    evaluation = catalog.products.first.sets.first.materialize!

    catalog.destroy!

    assert ActionAgent::Evaluation.exists?(evaluation.id)
    assert_equal 0, ActionAgent::ScenarioSet.count
    assert_equal 0, ActionAgent::CatalogScenario.count
  end
end
