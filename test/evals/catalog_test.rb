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

  # The fixture layered twice, then under any `overlays`: the first overlay
  # declares bars on the triage product and its smoke set, the second
  # lowers one key at each level.
  def gated_catalog(*overlays)
    ActiveAgent::Evals::Catalog.new([
      YAML.safe_load_file(File.join(FIXTURES, "support_catalog.yml")),
      { "products" => [ { "key" => "triage", "pass" => { "threshold" => 0.8, "min_pass_rate" => 0.9 },
                          "sets" => [ { "key" => "smoke", "pass" => { "gated" => false } } ] } ] },
      { "products" => [ { "key" => "triage", "pass" => { "min_pass_rate" => 0.5 },
                          "sets" => [ { "key" => "smoke", "pass" => { "min_pass_rate" => 0.75 } } ] } ] },
      *overlays
    ])
  end

  test "a product's and a set's pass block layer key by key and stay out of the metadata" do
    triage = gated_catalog.product(:triage)

    assert_equal({ "threshold" => 0.8, "min_pass_rate" => 0.5 }, triage.pass)
    assert_equal({ "gated" => false, "min_pass_rate" => 0.75 }, triage.set(:smoke).pass)
    assert_equal({}, triage.set(:production).pass)
    assert_equal({}, gated_catalog.product(:billing).pass)
    assert_equal({ "repository" => "example/support" }, triage.metadata)
    assert_equal({}, triage.set(:smoke).metadata)
    assert_equal({}, catalog.product(:triage).pass, "a product without a pass block has an empty one")
  end

  test "a suite document's pass block lands on the product it becomes" do
    suite_catalog = ActiveAgent::Evals::Catalog.parse(<<~YAML)
      suite: support_tasks
      pass: { min_pass_rate: 0.8 }
      groups:
        - key: orders
          pass: { gated: false }
          scenarios:
            - key: order_lookup
              prompt: Where is order ABC-123?
    YAML
    product = suite_catalog.product(:support_tasks)

    assert_equal({ "min_pass_rate" => 0.8 }, product.pass)
    assert_equal({ "gated" => false }, product.set(:orders).pass)
    assert_equal({}, suite_catalog.metadata)
  end

  test "pass blocks round-trip through the canonical document with the digest unchanged" do
    yaml = gated_catalog.to_yaml
    reparsed = ActiveAgent::Evals::Catalog.parse(yaml)

    assert_includes yaml, "pass:"
    assert_includes yaml, "min_pass_rate: 0.75"
    assert_equal gated_catalog.to_h, reparsed.to_h
    assert_equal gated_catalog.digest, reparsed.digest
    assert_equal({ "threshold" => 0.8, "min_pass_rate" => 0.5 }, reparsed.product(:triage).pass)
    assert_equal({ "gated" => false, "min_pass_rate" => 0.75 }, reparsed.set(:triage, :smoke).pass)
    assert_not_includes catalog.to_yaml, "pass:", "a catalog without bars writes none"
    assert_equal catalog.digest, ActiveAgent::Evals::Catalog.parse(catalog.to_yaml).digest
  end

  test "a product's suite and its pass thresholds carry the catalog's bars" do
    suite = gated_catalog.suite_for(:triage)
    thresholds = suite.pass_thresholds

    assert_equal 0.8, thresholds.threshold
    assert_equal 0.5, thresholds.min_pass_rate
    assert_equal 0.75, thresholds.min_pass_rate("smoke")
    assert_not thresholds.gated?("smoke")
    assert_equal 0.5, thresholds.min_pass_rate("production")
    assert thresholds.gated?("production")
    assert_equal({ "gated" => false, "min_pass_rate" => 0.75 }, suite.groups.first["pass"])
    assert_equal thresholds, gated_catalog.pass_thresholds(:triage)
    assert_equal ActiveAgent::Evals::PassThresholds.default, catalog.pass_thresholds(:billing)

    both = gated_catalog({ "products" => [ { "key" => "triage", "sets" => [ { "key" => "production", "pass" => { "min_pass_rate" => 0.9 } } ] } ] })
    assert_equal %w[smoke production], both.pass_thresholds(:triage).to_h["groups"].keys
    assert_equal %w[smoke], both.pass_thresholds("triage", "smoke").to_h["groups"].keys, "narrowed to one set, the other sets' bars are left out"
    assert_equal 0.5, both.pass_thresholds("triage", "smoke").min_pass_rate, "the product's bars still apply"
  end

  test "refuses a pass block the suite would refuse, naming the product or set it sits on" do
    error = assert_raises(ActiveAgent::Evals::Catalog::InvalidDocument) do
      ActiveAgent::Evals::Catalog.parse("catalog: x\nproducts: [{ key: triage, pass: { retries: 2 } }]")
    end
    assert_equal 'unknown key "retries" in "pass" of product "triage"; expected one of threshold, min_pass_rate', error.message

    error = assert_raises(ActiveAgent::Evals::Catalog::InvalidDocument) do
      ActiveAgent::Evals::Catalog.parse("catalog: x\nproducts: [{ key: triage, sets: [{ key: smoke, pass: { min_pass_rate: 2 } }] }]")
    end
    assert_equal '"min_pass_rate" in "pass" of set "smoke" of product "triage" must be a number from 0 to 1, got 2', error.message,
                 "a set is named the same way whatever is wrong with its block"

    error = assert_raises(ActiveAgent::Evals::Catalog::InvalidDocument) { ActiveAgent::Evals::Catalog.parse("suite: s\npass: 0.8\ngroups: []") }
    assert_equal '"pass" of product "s" must be a mapping, got 0.8', error.message

    error = assert_raises(ActiveAgent::Evals::Catalog::InvalidDocument) do
      ActiveAgent::Evals::Catalog.parse("catalog: x\nproducts: [{ key: triage, sets: [{ key: smoke, pass: [1] }] }]")
    end
    assert_equal '"pass" of set "smoke" of product "triage" must be a mapping, got [1]', error.message

    error = assert_raises(ActiveAgent::Evals::Catalog::InvalidDocument) do
      ActiveAgent::Evals::Catalog.new([ { "catalog" => "x", "products" => [ { "key" => "triage", "pass" => { "threshold" => 0.5 } } ] },
                                       { "products" => [ { "key" => "triage", "pass" => 0.8 } ] } ])
    end
    assert_equal '"pass" of product "triage" must be a mapping, got 0.8', error.message, "a layered document is held to the same check"
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
