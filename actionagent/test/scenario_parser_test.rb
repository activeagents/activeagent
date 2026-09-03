# frozen_string_literal: true

require "test_helper"

class ActionAgentScenarioParserTest < ActiveSupport::TestCase
  def parse(text)
    ActionAgent::ScenarioParser.parse(text)
  end

  test "one message per line, keyed by position" do
    scenarios = parse("Where is my order?\nCancel my subscription\n")

    assert_equal [ "Where is my order?", "Cancel my subscription" ], scenarios.map { |s| s["prompt"] }
    assert_equal [ "scenario_1", "scenario_2" ], scenarios.map { |s| s["key"] }
    assert_equal [ 0, 1 ], scenarios.map { |s| s["position"] }
  end

  test "headings start a group and list markers are stripped" do
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

  test "a backticked message keeps the rest of the line as notes" do
    scenarios = parse("3. `Show me all providers with no license on file` — ✏️ reworded: 1,060 of 15,043 physicians have no license row")

    assert_equal "Show me all providers with no license on file", scenarios.first["prompt"]
    assert_match(/reworded/, scenarios.first["notes"])
  end

  test "inline options declare expectations, keys and groups" do
    scenarios = parse("Why is this provider not showing? | tools: record_visibility_status, sync_status | contains: index | key: vis_1 | group: Diagnostics")

    scenario = scenarios.first
    assert_equal "Why is this provider not showing?", scenario["prompt"]
    assert_equal "vis_1", scenario["key"]
    assert_equal "Diagnostics", scenario["group"]
    assert_equal %w[record_visibility_status sync_status], scenario["expectations"]["tools"]
    assert_equal [ "index" ], scenario["expectations"]["contains"]
  end

  test "a JSON array of strings or objects is accepted" do
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

  test "explicit keys are kept and generated keys never collide with them" do
    scenarios = parse("# A\nfirst | key: a_1\nsecond")

    assert_equal [ "a_1", "a_2" ], scenarios.map { |s| s["key"] }
  end

  test "blank input parses to nothing" do
    assert_equal [], parse("  \n\n")
  end
end
