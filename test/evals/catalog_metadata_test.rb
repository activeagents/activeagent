# frozen_string_literal: true

require "test_helper"
require "active_agent/evals"

class EvalsCatalogMetadataTest < ActiveSupport::TestCase
  EXTRAS = {
    "priority" => "high", "weight" => 0, "reviewed" => false,
    "nullable" => nil, "empty_list" => [], "empty_object" => {}, "empty_text" => "",
    "details" => { "flags" => [ false, nil, 0 ], "source" => "synthetic" },
    "history" => [ { "z" => 1, "a" => 2 } ],
    "metadata" => { "team" => "support" }
  }.freeze

  def document(extras = EXTRAS)
    {
      "catalog" => "support",
      "products" => [ { "key" => "triage", "sets" => [ {
        "key" => "smoke", "scenarios" => [ {
          "key" => "hello", "prompt" => "Say hello.", "expect" => { "contains" => [ "hello" ] },
          "params" => { "locale" => "en" }, "tags" => [ "greeting" ]
        }.merge(extras) ]
      } ] } ]
    }
  end

  def scenario_document(catalog)
    catalog.to_h.dig("products", 0, "sets", 0, "scenarios", 0)
  end

  test "scenario extension fields survive YAML and JSON round trips without changing their values" do
    catalog = ActiveAgent::Evals::Catalog.new(document)
    exported = scenario_document(catalog)

    assert_equal EXTRAS, exported.slice(*EXTRAS.keys)
    assert_equal EXTRAS, catalog.scenarios.sole.metadata
    assert_equal catalog.to_h, ActiveAgent::Evals::Catalog.parse(catalog.to_yaml).to_h
    assert_equal catalog.to_h, ActiveAgent::Evals::Catalog.parse(JSON.generate(catalog.to_h)).to_h
    assert_equal catalog.digest, ActiveAgent::Evals::Catalog.parse(catalog.to_yaml).digest
    assert_equal({ "locale" => "en" }, exported["params"])
    assert_equal [ "greeting" ], exported["tags"]
  end

  test "changing only a scenario extension field changes the digest" do
    first = ActiveAgent::Evals::Catalog.new(document)
    second = ActiveAgent::Evals::Catalog.new(document(EXTRAS.merge("priority" => "low")))

    assert_not_equal first.digest, second.digest
  end

  test "extension object key order does not affect the digest but array order does" do
    original = ActiveAgent::Evals::Catalog.new(document)
    reordered = EXTRAS.to_a.reverse.to_h.merge("details" => { "source" => "synthetic", "flags" => [ false, nil, 0 ] })
    reordered["history"] = [ { "a" => 2, "z" => 1 } ]

    assert_equal original.digest, ActiveAgent::Evals::Catalog.new(document(reordered)).digest
    reordered["details"]["flags"] = [ 0, nil, false ]
    assert_not_equal original.digest, ActiveAgent::Evals::Catalog.new(document(reordered)).digest
  end

  test "a literal metadata extension can have any YAML value without becoming the serialization container" do
    [ nil, false, 0, [], "opaque" ].each do |value|
      catalog = ActiveAgent::Evals::Catalog.new(document({ "metadata" => value }))

      assert_equal({ "metadata" => value }, catalog.scenarios.sole.metadata)
      assert_equal({ "metadata" => value }, scenario_document(catalog).slice("metadata"))
    end
  end

  test "scenario metadata survives struct serialization and conversion to a suite" do
    catalog = ActiveAgent::Evals::Catalog.new(document)
    scenario = catalog.scenarios.sole
    restored = ActiveAgent::Evals::Scenario.from_hash(scenario.to_h)

    assert_equal EXTRAS, restored.metadata
    assert_equal scenario.prompt, restored.prompt
    assert_equal EXTRAS, catalog.suite_for("triage", "smoke").all_scenarios.sole.metadata
  end

  test "metadata cannot replace canonical fields or their expectation aliases" do
    catalog = ActiveAgent::Evals::Catalog.new(document)
    catalog.scenarios.sole.metadata.merge!(
      "key" => "forged", "prompt" => "Wrong prompt", "position" => 999,
      "expectations" => { "tools" => [ "wrong_tool" ] }, "tools" => [ "wrong_tool" ]
    )
    exported = scenario_document(catalog)

    assert_equal "hello", exported["key"]
    assert_equal "Say hello.", exported["prompt"]
    assert_equal({ "contains" => [ "hello" ] }, exported["expect"])
    assert_empty exported.keys & %w[expectations tools position]
  end

  test "a scenario without extension fields keeps its existing serialized shape" do
    scenario = ActiveAgent::Evals::Catalog.new(document({})).scenarios.sole

    assert_empty scenario.metadata
    assert_not_includes scenario.to_h.keys, :metadata
    assert_equal document({}).dig("products", 0, "sets", 0, "scenarios", 0),
      scenario_document(ActiveAgent::Evals::Catalog.new(document({})))
    plain = ActiveAgent::Evals::Scenario.from_hash({ "key" => "hello", "prompt" => "Say hello.", "metadata" => "opaque" })
    assert_not_includes plain.to_h.keys, :metadata
  end

  test "layering replaces a scenario's extensions with the incoming scenario" do
    catalog = ActiveAgent::Evals::Catalog.new([ document, document({ "priority" => "low" }) ])

    assert_equal({ "priority" => "low" }, catalog.scenarios.sole.metadata)
    assert_equal "low", scenario_document(catalog)["priority"]
    assert_not_includes scenario_document(catalog).keys, "details"
  end
end
