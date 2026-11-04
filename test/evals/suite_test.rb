# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"
require "tmpdir"

class EvalsSuiteTest < ActiveSupport::TestCase
  CORE = <<~YAML
    suite: support_desk
    description: Questions the support team asks every week
    pass:
      threshold: 0.8
      min_pass_rate: 0.9
    groups:
      - key: open_tickets
        name: Open tickets
        pass: { min_pass_rate: 1.0 }
        scenarios:
          - key: open_tickets_1
            prompt: Which tickets are waiting on the customer?
            expect:
              tools: [find_tickets, count_tickets]
          - key: open_tickets_2
            prompt: Which open tickets mention a refund?
      - key: reports
        name: Reports
        pass: { gated: false }
        scenarios:
          - key: reports_1
            prompt: How many tickets were reopened last month?
            production_only: true
  YAML

  CLIENT = <<~YAML
    groups:
      - key: open_tickets
        pass: { min_pass_rate: 0.5 }
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

  def test_the_suite_carries_the_bars_it_declares
    thresholds = ActiveAgent::Evals::Suite.new([ YAML.safe_load(CORE) ]).pass_thresholds

    assert_equal 0.8, thresholds.threshold
    assert_equal 0.9, thresholds.min_pass_rate
    assert_equal 1.0, thresholds.min_pass_rate("open_tickets")
    assert_equal 0.9, thresholds.min_pass_rate("reports")
    assert_not thresholds.gated?("reports")
    assert thresholds.gated?("open_tickets")
    assert_equal ActiveAgent::Evals::PassThresholds.default, ActiveAgent::Evals::Suite.new([ { "suite" => "bare", "groups" => [] } ]).pass_thresholds
  end

  def test_a_later_document_lowers_one_groups_bar_and_leaves_the_rest_alone
    with_files do |core, client|
      suite = ActiveAgent::Evals::Suite.load(core, client)
      thresholds = suite.pass_thresholds

      assert_equal 0.8, thresholds.threshold
      assert_equal 0.9, thresholds.min_pass_rate
      assert_equal 0.5, thresholds.min_pass_rate("open_tickets")
      assert_not thresholds.gated?("reports")
      assert_equal 0.9, thresholds.min_pass_rate("client_only")
      assert_equal({ "min_pass_rate" => 0.5 }, suite.groups.find { |group| group["key"] == "open_tickets" }["pass"])
      assert_equal({ "gated" => false }, suite.groups.find { |group| group["key"] == "reports" }["pass"])
      assert_equal thresholds, ActiveAgent::Evals::Suite.new([ YAML.safe_load(CORE), YAML.safe_load(CLIENT) ]).pass_thresholds
    end
  end

  def test_a_group_document_layers_its_pass_block_key_by_key
    suite = ActiveAgent::Evals::Suite.new([ YAML.safe_load(CORE), { "groups" => [ { "key" => "open_tickets", "pass" => { "gated" => false } } ] } ])

    assert_equal({ "min_pass_rate" => 1.0, "gated" => false }, suite.groups.first["pass"])
    assert_equal 1.0, suite.pass_thresholds.min_pass_rate("open_tickets")
    assert_not suite.pass_thresholds.gated?("open_tickets")
  end

  def test_an_invalid_pass_block_is_refused_when_the_suite_loads
    error = assert_raises(ArgumentError) { ActiveAgent::Evals::Suite.new([ YAML.safe_load(CORE), { "groups" => [ { "key" => "reports", "pass" => { "retries" => 2 } } ] } ]) }

    assert_includes error.message, '"retries"'
    assert_includes error.message, "group reports"
  end
end
