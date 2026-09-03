# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"

class EvalsScenarioParserTest < ActiveSupport::TestCase
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
