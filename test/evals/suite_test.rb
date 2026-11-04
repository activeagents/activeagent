# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"
require "tmpdir"

class EvalsSuiteTest < ActiveSupport::TestCase
  include EvalsTestSupport

  CORE = <<~YAML
    suite: support_desk
    description: Questions the support team asks every week
    criteria:
      shared:
        - key: cites_order
          type: contains
          config: { pattern: "ABC-" }
        - key: no_apology
          type: not_contains
          config: { pattern: sorry }
      terse:
        - key: short
          type: min_length
          config: { chars: 20 }
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
    criteria:
      shared:
        - key: cites_order
          type: contains
          config: { pattern: "ORD-" }
      terse:
        - key: no_filler
          type: not_contains
          config: { pattern: "as an AI" }
      agents_team:
        - key: names_tool
          type: contains
          config: { pattern: find_tickets }
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

  def test_criteria_lists_layer_by_name_and_key_across_documents
    with_files do |core, client|
      suite = ActiveAgent::Evals::Suite.load(core, client)

      assert_equal %w[shared terse agents_team], suite.criteria_names
      assert_equal %w[cites_order no_apology], suite.criteria("shared").map { |criterion| criterion["key"] }
      assert_equal({ "pattern" => "ORD-" }, suite.criteria("shared").first["config"])
      assert_equal %w[short no_filler], suite.criteria("terse").map { |criterion| criterion["key"] }
      assert_equal [ { "key" => "names_tool", "type" => "contains", "config" => { "pattern" => "find_tickets" } } ], suite.criteria(:agents_team)
    end
  end

  def test_criteria_joins_the_named_lists_in_the_order_given
    suite = ActiveAgent::Evals::Suite.new([ YAML.safe_load(CORE), YAML.safe_load(CLIENT) ])

    assert_equal %w[short no_filler cites_order no_apology], suite.criteria("terse", "shared").map { |criterion| criterion["key"] }
    assert_equal %w[cites_order no_apology short no_filler names_tool], suite.criteria.map { |criterion| criterion["key"] }
    assert_equal %w[cites_order no_apology], suite.criteria("shared", "shared").map { |criterion| criterion["key"] }
    assert_equal %w[cites_order no_apology], suite.criteria("shared", "missing").map { |criterion| criterion["key"] }
    assert_equal [], suite.criteria("missing")
    assert_equal suite.criteria, suite.criteria(nil)
    assert_equal %w[cites_order no_apology], suite.criteria("shared", nil, "").map { |criterion| criterion["key"] }
  end

  def test_a_later_list_restating_a_criterion_key_replaces_it_in_place
    suite = ActiveAgent::Evals::Suite.new([ {
      "criteria" => {
        "shared" => [ { "key" => "tone", "type" => "not_contains", "config" => { "pattern" => "sorry" } },
                      { "key" => "cites_order", "type" => "contains", "config" => { "pattern" => "ABC-" } } ],
        "patient" => [ { "key" => "tone", "type" => "llm_judge", "config" => { "rubric" => "Warm and plain." } } ]
      }
    } ])

    chosen = suite.criteria("shared", "patient")
    assert_equal %w[tone cites_order], chosen.map { |criterion| criterion["key"] }
    assert_equal "llm_judge", chosen.first["type"], "the audience's tone wins and is scored once"
    assert_equal "not_contains", suite.criteria("patient", "shared").first["type"], "the list named last wins"
  end

  def test_a_bare_criteria_list_reads_as_the_default_list
    suite = ActiveAgent::Evals::Suite.new([ { "criteria" => [ { "key" => "short", "type" => "min_length", "config" => { "chars" => 20 } } ] } ])
    layered = ActiveAgent::Evals::Suite.new([ YAML.safe_load(CORE), { "criteria" => [ { "key" => "polite", "type" => "not_contains", "config" => { "pattern" => "no way" } } ] } ])

    assert_equal [ "default" ], suite.criteria_names
    assert_equal [ { "key" => "short", "type" => "min_length", "config" => { "chars" => 20 } } ], suite.criteria("default")
    assert_equal %w[shared terse default], layered.criteria_names
    assert_equal [ "polite" ], layered.criteria("default").map { |criterion| criterion["key"] }
    assert_equal [], ActiveAgent::Evals::Suite.new([ { "criteria" => [] } ]).criteria_names
    assert_equal [], ActiveAgent::Evals::Suite.new([ { "criteria" => {} } ]).criteria_names
  end

  def test_a_symbol_keyed_document_reads_as_string_keyed_criteria
    suite = ActiveAgent::Evals::Suite.new([ { suite: :support_desk, criteria: { shared: [ { key: :cites_order, type: "contains", config: { pattern: "ABC-" } } ] } } ])

    assert_equal [ "shared" ], suite.criteria_names
    assert_equal [ { "key" => "cites_order", "type" => "contains", "config" => { "pattern" => "ABC-" } } ], suite.criteria(:shared)
  end

  def test_malformed_criteria_name_the_suite_and_the_list
    [ { "type" => "contains" }, { "key" => nil, "type" => "contains" }, { "key" => "", "type" => "contains" } ].each do |keyless|
      error = assert_raises(ArgumentError, keyless.inspect) do
        ActiveAgent::Evals::Suite.new([ { "suite" => "support_desk", "criteria" => { "shared" => [ keyless ] } } ])
      end
      assert_match(/a criterion in list "shared" of suite "support_desk" has no key/, error.message)
    end

    error = assert_raises(ArgumentError) do
      ActiveAgent::Evals::Suite.new([ { "suite" => "support_desk", "criteria" => { "shared" => [ "response_present" ] } } ])
    end
    assert_match(/a criterion in list "shared" of suite "support_desk" is not a mapping/, error.message)

    error = assert_raises(ArgumentError) { ActiveAgent::Evals::Suite.new([ { "suite" => "support_desk", "criteria" => "oops" } ]) }
    assert_match(/support_desk/, error.message)

    [ { "key" => "cites_order" }, nil ].each do |not_a_list|
      error = assert_raises(ArgumentError) do
        ActiveAgent::Evals::Suite.new([ { "suite" => "support_desk", "criteria" => { "shared" => not_a_list } } ])
      end
      assert_match(/criteria list "shared" of suite "support_desk" is not a list/, error.message)
    end

    error = assert_raises(ArgumentError) { ActiveAgent::Evals::Suite.new([ { "criteria" => "oops" } ]) }
    assert_match(/suite nil/, error.message)
  end

  def test_criteria_feed_the_runner_and_the_scorer
    suite = ActiveAgent::Evals::Suite.new([ YAML.safe_load(CORE), YAML.safe_load(CLIENT) ])
    runner = ActiveAgent::Evals::Runner.new(scenarios: [], models: [], replay: ->(*) { }, criteria: suite.criteria("shared", "terse"))
    scores = ActiveAgent::Evals::Scorer.new(criteria: suite.criteria("shared")).score(scenario, replay(answer: "Order ORD-42 shipped on Monday."))

    assert_equal %w[cites_order no_apology short no_filler], runner.criteria.map { |criterion| criterion["key"] }
    assert_equal({ "cites_order" => 1.0, "no_apology" => 1.0 }, scores)
  end
end
