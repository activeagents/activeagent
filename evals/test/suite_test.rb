# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class SuiteTest < Minitest::Test
  CORE = <<~YAML
    suite: clara_dashboard
    description: The V1 question catalog
    groups:
      - key: find_records
        name: Find record(s)
        scenarios:
          - key: find_records_1
            prompt: Which terms are under client control?
            expect:
              tools: [find_records, count_records]
          - key: find_records_2
            prompt: Which gynecologists in Charlotte have scheduling enabled?
      - key: analytics
        name: Analytics
        scenarios:
          - key: analytics_1
            prompt: How many appointments last month?
            production_only: true
  YAML

  CLIENT = <<~YAML
    groups:
      - key: find_records
        scenarios:
          - key: find_records_2
            prompt: Which cardiologists in Dallas have scheduling enabled?
          - key: find_records_99
            prompt: A client-specific question
      - key: client_only
        name: Client only
        scenarios:
          - key: client_only_1
            prompt: Another client question
  YAML

  def with_files
    Dir.mktmpdir do |dir|
      core = File.join(dir, "clara_dashboard.yml")
      client = File.join(dir, "client", "clara_dashboard.yml")
      File.write(core, CORE)
      Dir.mkdir(File.dirname(client))
      File.write(client, CLIENT)
      yield core, client
    end
  end

  def test_loads_a_suite_with_its_groups_and_scenarios
    with_files do |core, _client|
      suite = ActiveAgents::Evals::Suite.load(core)

      assert_equal "clara_dashboard", suite.name
      assert_equal "The V1 question catalog", suite.description
      assert_equal %w[find_records analytics], suite.group_keys
      assert_equal %w[find_records_1 find_records_2 analytics_1], suite.all_scenarios.map(&:key)
      assert_equal [ "find_records", "count_records" ], suite.find("find_records_1").expected_tools
      assert_equal "Find record(s)", suite.find("find_records_1").group_name
      assert_equal [ 0, 1, 0 ], suite.all_scenarios.map(&:position)
    end
  end

  def test_a_later_document_overrides_by_key_and_appends_the_rest
    with_files do |core, client|
      suite = ActiveAgents::Evals::Suite.load(core, client)

      assert_equal "Which cardiologists in Dallas have scheduling enabled?", suite.find("find_records_2").prompt
      assert_includes suite.scenarios(groups: [ "find_records" ]).map(&:key), "find_records_99"
      assert_equal "client_only", suite.group_keys.last
    end
  end

  def test_missing_files_are_skipped_and_none_at_all_raises
    with_files do |core, _client|
      suite = ActiveAgents::Evals::Suite.load(core, "/nowhere/clara_dashboard.yml")
      assert_equal 3, suite.all_scenarios.size
    end

    assert_raises(ActiveAgents::Evals::Suite::NotFound) { ActiveAgents::Evals::Suite.load("/nowhere/nope.yml") }
  end

  def test_scenarios_narrow_by_group_key_and_production_only
    suite = ActiveAgents::Evals::Suite.new([ YAML.safe_load(CORE) ])

    assert_equal [ "analytics_1" ], suite.scenarios(groups: %w[analytics]).map(&:key)
    assert_equal [ "find_records_2" ], suite.scenarios(keys: %w[find_records_2]).map(&:key)
    assert_equal %w[find_records_1 find_records_2], suite.scenarios(include_production_only: false).map(&:key)
  end

  def test_find_raises_for_an_unknown_key
    suite = ActiveAgents::Evals::Suite.new([ YAML.safe_load(CORE) ])

    assert_raises(ActiveAgents::Evals::Suite::NotFound) { suite.find("nope") }
  end
end
