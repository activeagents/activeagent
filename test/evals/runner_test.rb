# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"

class EvalsRunnerTest < ActiveSupport::TestCase
  include EvalsTestSupport

  def test_context_wrapper_covers_replay_judging_and_recommendation_before_on_result
    events = []
    current = nil
    task = scenario("order_1", "Where is order ABC-123?", group: "orders")
    model = spec("test-model")
    wrapper = lambda do |scenario, spec, &evaluate|
      current = [ scenario.key, spec.label ]
      events << :enter
      evaluate.call
    ensure
      events << :leave
      current = nil
    end
    judge = fake_judge do |*|
      assert_equal [ task.key, model.label ], current
      events << :judge
      '{"score": 0.2, "recommendation": "Use the actual order status."}'
    end
    report = ActiveAgent::Evals::Runner.new(
      scenarios: [ task ], models: [ model ], judge: judge, around_evaluation: wrapper,
      replay: ->(*) { assert_equal [ task.key, model.label ], current; events << :replay; replay(answer: "It may have shipped.") },
      on_result: ->(result) { assert_nil current; assert_equal "failed", result.status; events << :result }
    ).call

    assert_equal [ :enter, :replay, :judge, :judge, :leave, :result ], events
    assert_equal 1, report.results.size
  end

  def test_wrapper_errors_propagate_and_direct_evaluate_does_not_use_the_wrapper
    task = scenario("order_1", "Where is order ABC-123?", group: "orders")
    model = spec("test-model")
    runner = ActiveAgent::Evals::Runner.new(
      scenarios: [ task ], models: [ model ],
      around_evaluation: ->(*) { raise "context unavailable" },
      replay: ->(*) { flunk "the wrapper should fail before replay" }
    )

    assert_equal "context unavailable", assert_raises(RuntimeError) { runner.call }.message
    assert runner.evaluate(task, model, replay(answer: "The order shipped.")).passed?
  end

  def test_successful_tool_and_content_checks_cannot_override_failing_task_completion
    [ [ 0.2, {} ], [ 0.0, { contains: [ "ABC-123" ] } ] ].each do |grade, expectations|
      task = scenario("order_1", "Where is order ABC-123?", group: "orders", tools: [ "lookup_order" ], **expectations)
      judge = fake_judge { |*| { score: grade, recommendation: "Use the actual order status." }.to_json }
      report = ActiveAgent::Evals::Runner.new(
        scenarios: [ task ], models: [ spec("test-model") ], judge: judge,
        available_tools: [ "lookup_order" ],
        replay: ->(*) { replay(answer: "ABC-123 probably shipped.", tool_calls: [ { name: "lookup_order" } ]) }
      ).call
      result = report.results.first

      assert_operator result.score, :>=, ActiveAgent::Evals::PASS_THRESHOLD
      assert_equal grade, result.scores["task_completion"]
      assert_equal "failed", result.status
      assert_equal "low_quality", result.fault
      assert_includes result.summary, "Task completion scored #{grade}"
      assert_equal "Use the actual order status.", result.recommendation
      assert_equal 0.0, report.summary_by_model["test-model"]["pass_rate"]
      assert_equal grade, report.summary_by_model["test-model"]["avg_task_completion"]
      assert_includes report.to_markdown, "low quality"
    end
  end

  def test_task_completion_uses_the_configured_threshold_and_preserves_unscorable_fallback
    [ [ 0.8, "passed" ], [ 0.79, "failed" ], [ nil, "passed" ] ].each do |grade, status|
      judge = fake_judge { |*| { score: grade }.to_json }
      report = ActiveAgent::Evals::Runner.new(
        scenarios: [ scenario("order_1", "Where is order ABC-123?", tools: [ "lookup_order" ]) ],
        models: [ spec("test-model") ], judge: judge, threshold: 0.8,
        replay: ->(*) { replay(answer: "The order shipped.", tool_calls: [ { name: "lookup_order" } ]) }
      ).call

      assert_equal status, report.results.first.status
    end
  end

  CRITERIA = [ { "key" => "response_present", "type" => "response_present" } ].freeze

  def scenarios
    [
      scenario("find_1", "Which gynecologists in Charlotte have scheduling enabled?", group: "find"),
      scenario("find_2", "Show me all providers with no license on file", group: "find", tools: [ "find_records" ]),
      scenario("blame_1", "Who changed the biography?", group: "blame")
    ]
  end

  def models
    ActiveAgent::Evals::ModelSpec.parse_all(%w[gpt-5-mini qwen3:8b], default_provider: "openai")
  end

  # A stand-in agent: answers with the model name, calls find_records only for
  # the "license" question on gpt, and refuses the blame question on qwen.
  def replay_agent(scenario, spec)
    return Replay.new(answer: "I don't have access to change history.", duration_ms: 100) if scenario.group == "blame" && spec.provider == "ollama"

    calls = scenario.prompt.include?("license") && spec.provider == "openai" ? [ { "name" => "find_records", "arguments" => { "model" => "Physician" } } ] : []
    Replay.new(answer: "#{spec.model} says: 12 providers match.", tool_calls: calls, duration_ms: 250, input_tokens: 10, output_tokens: 5, cost: 0.001)
  end

  def runner(**options)
    ActiveAgent::Evals::Runner.new(
      scenarios: scenarios, models: models, criteria: CRITERIA,
      available_tools: { "find_records" => "Look up records", "fetch_url" => "Fetch a page" },
      replay: method(:replay_agent), **options
    )
  end

  def test_every_scenario_runs_once_per_model_and_results_arrive_as_they_land
    landed = []
    report = runner(on_result: ->(result) { landed << [ result.scenario.key, result.label ] }).call

    assert_equal 6, report.results.size
    assert_equal [ %w[find_1 gpt-5-mini], %w[find_1 qwen3:8b] ], landed.first(2)
    assert_equal %w[gpt-5-mini qwen3:8b], report.models.map(&:label)
  end

  def test_faults_are_assigned_from_the_evidence_and_rolled_up
    report = runner.call
    by_key = report.results.group_by { |result| [ result.scenario.key, result.label ] }

    assert by_key[%w[find_1 gpt-5-mini]].first.passed?
    assert_equal "expected_tool_not_called", by_key[%w[find_2 qwen3:8b]].first.fault
    assert by_key[%w[find_2 gpt-5-mini]].first.passed?
    assert_equal "missing_capability", by_key[%w[blame_1 qwen3:8b]].first.fault

    summary = report.summary_by_model
    assert_equal 100.0, summary["gpt-5-mini"]["pass_rate"]
    assert_equal 33.3, summary["qwen3:8b"]["pass_rate"]
    assert_equal({ "expected_tool_not_called" => 1, "missing_capability" => 1 }, summary["qwen3:8b"]["faults"])
    assert_equal 0.002, summary["qwen3:8b"]["cost"]

    faults = report.recommendations.map { |entry| entry["fault"] }
    assert_equal %w[expected_tool_not_called missing_capability], faults.sort
    assert_equal "gpt-5-mini", report.winner
    assert_equal "pass rate", report.verdict["judge"]
  end

  def test_criterion_scores_are_cohort_maps_when_comparing_and_flat_otherwise
    comparing = runner.call.criterion_scores
    single = ActiveAgent::Evals::Runner.new(scenarios: scenarios, models: models.first(1), criteria: CRITERIA,
                                             replay: method(:replay_agent)).call.criterion_scores

    assert_equal %w[gpt-5-mini qwen3:8b], comparing["response_present"].keys
    assert_equal 1.0, comparing.dig("response_present", "gpt-5-mini", "score")
    assert_equal 0.0, comparing.dig("expected_tools", "qwen3:8b", "score")
    assert_equal 3, single["response_present"]["total"]
  end

  def test_a_replay_that_raises_becomes_an_errored_result_and_the_run_continues
    report = ActiveAgent::Evals::Runner.new(
      scenarios: scenarios.first(2), models: models.first(1),
      replay: ->(_scenario, _spec) { raise "provider down" }
    ).call

    assert_equal 2, report.results.size
    assert report.results.all?(&:errored?)
    assert_equal "run_error", report.results.first.fault
    assert_match(/provider down/, report.results.first.replay.error)
    assert_equal 2, report.summary_by_model["gpt-5-mini"]["errored"]
  end

  def test_a_hash_replay_is_accepted
    report = ActiveAgent::Evals::Runner.new(
      scenarios: scenarios.first(1), models: models.first(1),
      replay: ->(_scenario, _spec) { { answer: "12 providers match.", tool_calls: [ { name: "find_records" } ] } }
    ).call

    assert report.results.first.passed?
    assert_equal [ "find_records" ], report.results.first.replay.tool_names
  end

  def test_the_judge_scores_task_completion_refines_recommendations_and_writes_the_verdict
    judge = fake_judge(label: "claude-opus-5") do |instructions, prompt|
      if instructions.include?("comparing model cohorts")
        '{"winner": "qwen3:8b", "rationale": "Cheaper and just as complete."}'
      elsif instructions.include?("recommend the fix")
        '{"recommendation": "Add an audit tool.", "suggested_tool": {"name": "record_history", "description": "Who changed what"}}'
      elsif prompt.include?("Who changed the biography?")
        '{"score": 0.2}'
      else
        '{"score": 0.9}'
      end
    end

    report = runner(judge: judge, instructions: "Answer from data.").call
    blame_gpt = report.results.find { |result| result.scenario.key == "blame_1" && result.label == "gpt-5-mini" }
    blame_qwen = report.results.find { |result| result.scenario.key == "blame_1" && result.label == "qwen3:8b" }

    assert_equal 0.2, blame_gpt.scores["task_completion"]
    assert_equal "low_quality", blame_gpt.fault
    assert_equal "Add an audit tool.", blame_gpt.recommendation
    assert_equal({ "name" => "record_history", "description" => "Who changed what" }, blame_gpt.suggested_tool)
    assert_equal "missing_capability", blame_qwen.fault
    assert_equal "qwen3:8b", report.winner
    assert_equal "claude-opus-5", report.verdict["judge"]
    assert_includes report.recommendations.flat_map { |entry| entry["suggested_tools"] }, { "name" => "record_history", "description" => "Who changed what" }
  end

  def test_a_failing_judge_degrades_to_rule_scoring
    judge = fake_judge { |_instructions, _prompt| raise "judge offline" }

    report = runner(judge: judge).call

    assert_nil report.results.first.scores["task_completion"]
    assert_equal "pass rate", report.verdict["judge"]
  end

  def test_the_report_renders_markdown_and_json
    report = runner.call
    markdown = report.to_markdown
    parsed = JSON.parse(report.to_json)

    assert_includes markdown, "| `gpt-5-mini` | 100.0% | 3/3 |"
    assert_includes markdown, "**Best model: gpt-5-mini**"
    assert_includes markdown, "| `blame_1` Who changed the biography? | ✅ 1.0 | ❌ 1.0 missing capability |"
    assert_includes markdown, "- **missing capability** ×1 (blame_1):"
    assert_equal "gpt-5-mini", parsed["verdict"]["winner"]
    assert_equal 6, parsed["results"].size
  end

  def test_the_report_renders_a_self_contained_html_page
    report = runner.call
    html = report.to_html

    assert_includes html, "<!doctype html>"
    assert_includes html, "<style>"
    assert_no_match(%r{(?:src|href)=["']https?://}i, html, "the page must not reference external assets")
    assert_includes html, "gpt-5-mini"
    assert_includes html, "Recommendations"
    assert_includes html, "<details>"
    assert_includes html, "Who changed the biography?"
  end

  def test_html_report_escapes_answer_markup
    report = ActiveAgent::Evals::Report.new(
      results: [ ActiveAgent::Evals::Result.new(
        scenario: scenario("xss_1", "<script>alert(1)</script> in a prompt"),
        spec: spec("gpt-5-mini"),
        replay: replay(answer: "<img src=x onerror=alert(1)>"),
        scores: { "response_present" => 1.0 }, score: 1.0, status: "passed"
      ) ],
      models: [ spec("gpt-5-mini") ]
    )
    html = report.to_html

    assert_not_includes html, "<script>alert(1)</script>"
    assert_not_includes html, "<img src=x"
    assert_includes html, "&lt;script&gt;"
  end

  def test_an_argument_error_inside_the_replay_is_an_errored_result_not_an_aborted_run
    report = ActiveAgent::Evals::Runner.new(
      scenarios: scenarios.first(1), models: models,
      replay: lambda { |_scenario, spec|
        raise ArgumentError, "Invalid Ollama Chat request parameters" if spec.provider == "ollama"

        Replay.new(answer: "12 providers match.")
      }
    ).call

    assert_equal %w[passed errored], report.results.map(&:status)
    assert_match(/ArgumentError: Invalid Ollama/, report.results.last.replay.error)
  end

  def test_a_replay_that_returns_neither_a_replay_nor_a_hash_is_the_callers_bug
    runner = ActiveAgent::Evals::Runner.new(scenarios: scenarios.first(1), models: models.first(1), replay: ->(_scenario, _spec) { "nope" })

    assert_raises(ArgumentError) { runner.call }
  end

  def test_the_verdict_ranks_a_model_with_no_cost_estimate_after_one_with_a_known_cost
    # Both models pass everything; qwen3:8b reports no cost and gpt-5-mini
    # does. Unknown is not free, so the priced model wins the tie-break
    # whichever order the models were requested in.
    replay = lambda do |_scenario, spec|
      Replay.new(answer: "12 providers match.", cost: spec.provider == "openai" ? 0.001 : nil)
    end

    [ %w[qwen3:8b gpt-5-mini], %w[gpt-5-mini qwen3:8b] ].each do |names|
      specs = ActiveAgent::Evals::ModelSpec.parse_all(names, default_provider: "openai")
      report = ActiveAgent::Evals::Runner.new(scenarios: scenarios.first(1), models: specs, criteria: CRITERIA, replay: replay).call

      assert_equal 2, report.results.count(&:passed?)
      assert_nil report.summary_by_model["qwen3:8b"]["cost"]
      assert_equal "gpt-5-mini", report.winner, "models requested as #{names.join(', ')}"
    end
  end

  def test_a_prompt_containing_a_pipe_does_not_break_the_markdown_matrix
    piped = [ scenario("s_1", "Compare A | B for price", group: "compare") ]
    report = ActiveAgent::Evals::Runner.new(scenarios: piped, models: models.first(1), replay: ->(*) { Replay.new(answer: "ok") }).call
    row = report.to_markdown.lines.find { |line| line.include?("`s_1`") }

    assert_includes row, "Compare A \\| B for price | ✅ |"
  end
end
