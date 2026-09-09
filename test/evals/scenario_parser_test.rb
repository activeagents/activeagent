# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"

class EvalsScenarioParserTest < ActiveSupport::TestCase
  SUPPORT_SUITE = File.expand_path("fixtures/support_suite.yml", __dir__)

  def test_yaml_suite_import_retains_catalog_metadata_and_expectations
    parsed = ActiveAgent::Evals::ScenarioParser.scenarios(File.read(SUPPORT_SUITE))

    assert_equal %w[order_lookup live_volume help_cancel], parsed.map(&:key)
    assert_equal %w[orders orders help], parsed.map(&:group)
    assert_equal [ "Order support", "Order support", "Product help" ], parsed.map(&:group_name)
    assert_equal [ "lookup_order" ], parsed.first.expected_tools
    assert_equal [ "ABC-123" ], parsed.first.expected_patterns
    assert_equal [ "password" ], parsed.first.forbidden_patterns
    assert_equal "Use the synthetic test order.", parsed.first.notes
    assert parsed.second.production_only?
    assert_not parsed.first.production_only?
  end

  def test_suite_import_can_exclude_production_scenarios_without_changing_remaining_keys
    parsed = ActiveAgent::Evals::ScenarioParser.parse(File.read(SUPPORT_SUITE), include_production_only: false)

    assert_equal %w[order_lookup help_cancel], parsed.map { |entry| entry["key"] }
    assert_equal [ 0, 2 ], parsed.map { |entry| entry["position"] }
  end

  def test_json_suite_has_the_same_import_contract_as_yaml
    yaml = File.read(SUPPORT_SUITE)
    json = YAML.safe_load(yaml).to_json

    assert_equal parse(yaml), parse(json)
    assert_equal %w[order_lookup help_cancel],
                 ActiveAgent::Evals::ScenarioParser.scenarios(json, include_production_only: false).map(&:key)
  end

  def test_json_scenario_attributes_preserve_group_name_and_production_selection
    text = [ { key: "live_1", prompt: "Count orders today.", group: "orders",
               group_name: "Order support", production_only: true } ].to_json

    assert_equal "Order support", parse(text).first["group_name"]
    assert parse(text).first["production_only"]
    assert_empty ActiveAgent::Evals::ScenarioParser.parse(text, include_production_only: false)
  end

  def test_broken_yaml_suites_raise_instead_of_becoming_line_scenarios
    [ "suite: support\ngroups: [", "suite: support\ngroups: wrong", "suite: support\ngroups: !ruby/object:Object {}",
      "groups:\n  - invalid", "groups:\n  - scenarios: wrong", "groups:\n  - scenarios: [invalid]",
      "groups:\n  - scenarios:\n      - prompt: Valid question\n        expect: wrong" ].each do |text|
      assert_raises(ArgumentError) { parse(text) }
    end
  end

  def parse(text)
    ActiveAgent::Evals::ScenarioParser.parse(text)
  end

  def test_one_message_per_line_keyed_by_position
    scenarios = parse("Where is my order?\nCancel my subscription\n")

    assert_equal [ "Where is my order?", "Cancel my subscription" ], scenarios.map { |s| s["prompt"] }
    assert_equal [ "scenario_1", "scenario_2" ], scenarios.map { |s| s["key"] }
    assert_equal [ 0, 1 ], scenarios.map { |s| s["position"] }
  end

  def test_headings_start_a_group_and_list_markers_are_stripped
    scenarios = parse(<<~TEXT)
      # Find records
      1. Which gynecologists in Charlotte have scheduling enabled?
      - Show me all providers with no license on file

      **Blame / audit**
      * Who changed the biography for Dr. AbdelRazek?
    TEXT

    assert_equal [ "Find records", "Find records", "Blame / audit" ], scenarios.map { |s| s["group"] }
    assert_equal [ "find_records_1", "find_records_2", "blame_audit_1" ], scenarios.map { |s| s["key"] }
    assert_equal "Who changed the biography for Dr. AbdelRazek?", scenarios.last["prompt"]
  end

  def test_a_backticked_message_keeps_the_rest_of_the_line_as_notes
    scenarios = parse("3. `Show me all providers with no license on file` — ✏️ reworded: 1,060 of 15,043 physicians have no license row")

    assert_equal "Show me all providers with no license on file", scenarios.first["prompt"]
    assert_match(/reworded/, scenarios.first["notes"])
  end

  def test_inline_options_declare_expectations_keys_and_groups
    scenarios = parse("Why is this provider not showing? | tools: record_visibility_status, sync_status | contains: index | key: vis_1 | group: Diagnostics")

    scenario = scenarios.first
    assert_equal "Why is this provider not showing?", scenario["prompt"]
    assert_equal "vis_1", scenario["key"]
    assert_equal "Diagnostics", scenario["group"]
    assert_equal %w[record_visibility_status sync_status], scenario["expectations"]["tools"]
    assert_equal [ "index" ], scenario["expectations"]["contains"]
  end

  def test_a_json_array_of_strings_or_objects_is_accepted
    scenarios = parse(<<~JSON)
      [
        "Plain question",
        {"prompt": "Who added the term?", "group": "Blame", "tools": ["find_records"], "not_contains": ["I cannot"]}
      ]
    JSON

    assert_equal "Plain question", scenarios.first["prompt"]
    assert_equal "Blame", scenarios.last["group"]
    assert_equal [ "find_records" ], scenarios.last["expectations"]["tools"]
    assert_equal [ "I cannot" ], scenarios.last["expectations"]["not_contains"]
  end

  def test_explicit_keys_are_kept_and_generated_keys_never_collide_with_them
    scenarios = parse("# A\nfirst | key: a_1\nsecond")

    assert_equal [ "a_1", "a_2" ], scenarios.map { |s| s["key"] }
  end

  def test_a_named_key_that_repeats_an_earlier_line_is_reassigned
    scenarios = parse("# A\nfirst | key: a_1\nsecond | key: a_1\nthird")

    assert_equal %w[a_1 a_2 a_3], scenarios.map { |s| s["key"] }
  end

  def test_a_short_line_ending_in_a_colon_starts_a_group_unless_it_is_a_question_or_carries_options
    scenarios = parse("Find records:\nWhich providers have no license?\nWho changed it? | notes:")

    assert_equal [ "Which providers have no license?", "Who changed it?" ], scenarios.map { |s| s["prompt"] }
    assert_equal [ "Find records", "Find records" ], scenarios.map { |s| s["group"] }
    assert_nil scenarios.last["notes"]
  end

  def test_a_hash_that_opens_a_message_is_not_a_heading
    scenarios = parse("#1 priority: who changed the biography?\n# Blame\nWho changed it?")

    assert_equal [ "#1 priority: who changed the biography?", "Who changed it?" ], scenarios.map { |s| s["prompt"] }
    assert_equal [ nil, "Blame" ], scenarios.map { |s| s["group"] }
  end

  def test_inline_code_in_a_message_is_kept_as_part_of_the_prompt
    scenarios = parse("What does `count_records` return for Charlotte?\n`Show me all providers` — 314 locally")

    assert_equal "What does count_records return for Charlotte?", scenarios.first["prompt"]
    assert_nil scenarios.first["notes"]
    assert_equal "Show me all providers", scenarios.last["prompt"]
    assert_equal "314 locally", scenarios.last["notes"]
  end

  def test_a_single_json_object_and_an_expect_sub_hash_are_accepted
    scenarios = parse('{"prompt": "Where is my order?", "expect": {"tools": ["lookup_order"]}}')

    assert_equal [ "Where is my order?" ], scenarios.map { |s| s["prompt"] }
    assert_equal [ "lookup_order" ], scenarios.first["expectations"]["tools"]
  end

  def test_blank_input_parses_to_nothing
    assert_equal [], parse("  \n\n")
  end

  def test_scenarios_builds_structs
    scenario = ActiveAgent::Evals::ScenarioParser.scenarios("# Blame\nWho? | tools: history").first

    assert_kind_of ActiveAgent::Evals::Scenario, scenario
    assert_equal "blame_1", scenario.key
    assert_equal [ "history" ], scenario.expected_tools
    assert_equal({ "tools" => [ "history" ] }, scenario.expectations)
  end
end
