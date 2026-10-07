# frozen_string_literal: true

require "test_helper"
require "active_agent/evals"

class ActiveAgentEvalsCatalogTest < ActiveSupport::TestCase
  FIXTURES = File.expand_path("fixtures", __dir__)

  def catalog
    @catalog ||= ActiveAgent::Evals::Catalog.load(File.join(FIXTURES, "support_catalog.yml"))
  end

  test "loads products, sets and scenarios from a catalog document" do
    assert_equal "support_desk", catalog.key
    assert_equal "Support Desk", catalog.name
    assert_equal({ "owner_team" => "support" }, catalog.metadata)
    assert_equal %w[triage billing], catalog.products.map(&:key)

    triage = catalog.product(:triage)
    assert_equal "TriageAgent", triage.agent
    assert_equal({ "repository" => "example/support" }, triage.metadata)
    assert_equal %w[smoke production], triage.sets.map(&:key)
    assert_equal({ "kind" => "rules" }, catalog.set(:triage, :smoke).judge)
    assert_equal 4, catalog.scenario_count
  end

  test "scenarios carry their set as group, with tags and params kept" do
    refund = catalog.scenarios(product: :triage, keys: [ "refund_request" ]).sole

    assert_equal "smoke", refund.group
    assert_equal "Smoke", refund.group_name
    assert_equal [ "lookup_order" ], refund.expected_tools
    assert_equal [ "refund" ], refund.expected_patterns
    assert_equal [ "billing" ], refund.tags
    assert_equal({ "locale" => "en" }, refund.params)
    assert_equal({ "tools" => [ "lookup_order" ], "contains" => [ "refund" ] }, refund.expectations)
  end

  test "narrows by product, set and production_only" do
    assert_equal %w[refund_request angry_customer open_tickets], catalog.scenarios(product: :triage).map(&:key)
    assert_equal %w[refund_request angry_customer], catalog.scenarios(product: :triage, include_production_only: false).map(&:key)
    assert_equal %w[open_tickets], catalog.scenarios(set: :production).map(&:key)
    assert_equal %w[invoice_copy], catalog.scenarios(product: :billing).map(&:key)
  end

  test "a product's sets read as a suite of groups" do
    suite = catalog.suite_for(:triage)
    assert_equal "support_desk/triage", suite.name
    assert_equal %w[smoke production], suite.group_keys
    assert_equal 3, suite.all_scenarios.size

    one_set = catalog.suite_for(:triage, :smoke)
    assert_equal "support_desk/triage/smoke", one_set.name
    assert_equal %w[refund_request angry_customer], one_set.all_scenarios.map(&:key)
  end

  test "a suite document is a catalog of one product whose sets are its groups" do
    suite_catalog = ActiveAgent::Evals::Catalog.load(File.join(FIXTURES, "support_suite.yml"))
    suite = ActiveAgent::Evals::Suite.load(File.join(FIXTURES, "support_suite.yml"))

    assert_equal 1, suite_catalog.products.size
    assert_equal suite.name, suite_catalog.key
    assert_equal suite.group_keys, suite_catalog.products.first.sets.map(&:key)
    assert_equal suite.all_scenarios.map(&:key), suite_catalog.scenarios.map(&:key)
  end

  test "later documents layer over earlier ones by key" do
    layered = ActiveAgent::Evals::Catalog.new([
      YAML.safe_load_file(File.join(FIXTURES, "support_catalog.yml")),
      { "products" => [ { "key" => "triage", "agent" => "TriageAgentV2", "sets" => [
        { "key" => "smoke", "scenarios" => [
          { "key" => "refund_request", "prompt" => "A customer asks for a refund on order 2042." },
          { "key" => "late_delivery", "prompt" => "My parcel is a week late." }
        ] },
        { "key" => "regressions", "name" => "Regressions", "scenarios" => [ { "key" => "r1", "prompt" => "Reopen ticket 9." } ] }
      ] } ] }
    ])

    assert_equal "TriageAgentV2", layered.product(:triage).agent
    assert_equal %w[smoke production regressions], layered.product(:triage).sets.map(&:key)
    assert_equal %w[refund_request angry_customer late_delivery], layered.set(:triage, :smoke).scenarios.map(&:key)
    assert_equal "A customer asks for a refund on order 2042.", layered.scenarios(keys: [ "refund_request" ]).sole.prompt
    assert_equal "Billing agent", layered.product(:billing).name
  end

  test "writes a canonical document that reads back the same, with a stable digest" do
    yaml = catalog.to_yaml
    reparsed = ActiveAgent::Evals::Catalog.parse(yaml)

    assert_equal catalog.to_h, reparsed.to_h
    assert_equal catalog.digest, reparsed.digest
    assert_equal catalog.digest, ActiveAgent::Evals::Catalog.parse(reparsed.to_yaml).digest
    assert_includes yaml, "catalog: support_desk"
    assert_includes yaml, "production_only: true"
    assert_not_includes yaml, "production_only: false"
    assert_equal({ "repository" => "example/support" }, reparsed.product(:triage).metadata)
  end

  test "refuses documents that are not a catalog, and entries without keys or prompts" do
    assert_raises(ActiveAgent::Evals::Catalog::InvalidDocument) { ActiveAgent::Evals::Catalog.parse("- just\n- a list\n") }
    assert_raises(ActiveAgent::Evals::Catalog::InvalidDocument) { ActiveAgent::Evals::Catalog.parse("catalog: x\nproducts: [{ name: no key }]") }
    assert_raises(ActiveAgent::Evals::Catalog::InvalidDocument) do
      ActiveAgent::Evals::Catalog.parse("catalog: x\nproducts: [{ key: p, sets: [{ key: s, scenarios: [{ key: k }] }] }]")
    end
    assert_raises(ActiveAgent::Evals::Catalog::InvalidDocument) { ActiveAgent::Evals::Catalog.parse("products: [{ key: p }]") }
    assert_raises(ActiveAgent::Evals::Catalog::InvalidDocument) { ActiveAgent::Evals::Catalog.parse("catalog: [\n") }
    assert_raises(ActiveAgent::Evals::Catalog::NotFound) { catalog.product(:nope) }
    assert_raises(ActiveAgent::Evals::Catalog::NotFound) { catalog.set(:triage, :nope) }
    assert_raises(ActiveAgent::Evals::Catalog::NotFound) { ActiveAgent::Evals::Catalog.load(File.join(FIXTURES, "missing.yml")) }
  end
end
