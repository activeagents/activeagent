# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"
require "tmpdir"

class EvalsSuiteTest < ActiveSupport::TestCase
  CORE = <<~YAML
    suite: support_desk
    description: Questions the support team asks every week
    groups:
      - key: open_tickets
        name: Open tickets
        scenarios:
          - key: open_tickets_1
            prompt: Which tickets are waiting on the customer?
            expect:
              tools: [find_tickets, count_tickets]
          - key: open_tickets_2
            prompt: Which open tickets mention a refund?
      - key: reports
        name: Reports
        scenarios:
          - key: reports_1
            prompt: How many tickets were reopened last month?
            production_only: true
  YAML

  CLIENT = <<~YAML
    groups:
      - key: open_tickets
        scenarios:
          - key: open_tickets_2
            prompt: Which open tickets mention a late delivery?
          - key: open_tickets_99
            prompt: A client-specific question
      - key: client_only
        name: Client only
        scenarios:
          - key: client_only_1
            prompt: Another client question
  YAML

  def with_files
    Dir.mktmpdir do |dir|
      core = File.join(dir, "support_desk.yml")
      client = File.join(dir, "client", "support_desk.yml")
      File.write(core, CORE)
      Dir.mkdir(File.dirname(client))
      File.write(client, CLIENT)
      yield core, client
    end
  end

  def test_loads_a_suite_with_its_groups_and_scenarios
    with_files do |core, _client|
      suite = ActiveAgent::Evals::Suite.load(core)

      assert_equal "support_desk", suite.name
      assert_equal "Questions the support team asks every week", suite.description
      assert_equal %w[open_tickets reports], suite.group_keys
      assert_equal %w[open_tickets_1 open_tickets_2 reports_1], suite.all_scenarios.map(&:key)
      assert_equal [ "find_tickets", "count_tickets" ], suite.find("open_tickets_1").expected_tools
      assert_equal "Open tickets", suite.find("open_tickets_1").group_name
      assert_equal [ 0, 1, 0 ], suite.all_scenarios.map(&:position)
    end
  end

  def test_a_later_document_overrides_by_key_and_appends_the_rest
    with_files do |core, client|
      suite = ActiveAgent::Evals::Suite.load(core, client)

      assert_equal "Which open tickets mention a late delivery?", suite.find("open_tickets_2").prompt
      assert_includes suite.scenarios(groups: [ "open_tickets" ]).map(&:key), "open_tickets_99"
      assert_equal "client_only", suite.group_keys.last
    end
  end

  def test_missing_files_are_skipped_and_none_at_all_raises
    with_files do |core, _client|
      suite = ActiveAgent::Evals::Suite.load(core, "/nowhere/support_desk.yml")
      assert_equal 3, suite.all_scenarios.size
    end

    assert_raises(ActiveAgent::Evals::Suite::NotFound) { ActiveAgent::Evals::Suite.load("/nowhere/nope.yml") }
  end

  def test_scenarios_narrow_by_group_key_and_production_only
    suite = ActiveAgent::Evals::Suite.new([ YAML.safe_load(CORE) ])

    assert_equal [ "reports_1" ], suite.scenarios(groups: %w[reports]).map(&:key)
    assert_equal [ "open_tickets_2" ], suite.scenarios(keys: %w[open_tickets_2]).map(&:key)
    assert_equal %w[open_tickets_1 open_tickets_2], suite.scenarios(include_production_only: false).map(&:key)
  end

  def test_find_raises_for_an_unknown_key
    suite = ActiveAgent::Evals::Suite.new([ YAML.safe_load(CORE) ])

    assert_raises(ActiveAgent::Evals::Suite::NotFound) { suite.find("nope") }
  end
end
