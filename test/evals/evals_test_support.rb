# frozen_string_literal: true

# Builders shared by the evaluation tests. Loaded by each test file after the
# dummy app's test_helper.
module EvalsTestSupport
  Scenario = ActiveAgent::Evals::Scenario
  Replay = ActiveAgent::Evals::Replay
  ModelSpec = ActiveAgent::Evals::ModelSpec
  Result = ActiveAgent::Evals::Result
  Diagnosis = ActiveAgent::Evals::Diagnosis
  Report = ActiveAgent::Evals::Report
  PassThresholds = ActiveAgent::Evals::PassThresholds

  # The tools the diagnosis of a built result knows about.
  AVAILABLE = %w[find_tickets inbox_status index_status].freeze

  # The bars of the gated report: orders must pass fully, experimental is
  # reported but not gated, and every other group follows the suite's 80%.
  THRESHOLDS = PassThresholds.new(
    suite: { "threshold" => 0.7, "min_pass_rate" => 0.8 },
    groups: { "orders" => { "min_pass_rate" => 1.0 }, "experimental" => { "gated" => false } }
  )

  # Bars the gated report clears: half of a model's answers may fail.
  LENIENT = PassThresholds.new(suite: { "min_pass_rate" => 0.5 }, groups: { "experimental" => { "gated" => false } })

  def scenario(key = "s_1", prompt = "Who changed the shipping policy?", group: "history", **expectations)
    Scenario.from_hash({ "key" => key, "prompt" => prompt, "expectations" => expectations.transform_keys(&:to_s) }, group: group)
  end

  def spec(label, provider: "openai")
    ModelSpec.parse(label, default_provider: provider)
  end

  def replay(answer: "Alice changed it on Monday.", **attributes)
    Replay.new(answer: answer, **attributes)
  end

  # A judge whose completions come from a hash of `instructions fragment => reply`.
  def fake_judge(label: "judge", &block)
    ActiveAgent::Evals::Judge.new(label: label) { |instructions:, prompt:| block.call(instructions, prompt) }
  end

  # --- a gated report ---------------------------------------------------------

  def models
    @models ||= [ spec("gpt-5-mini"), spec("openrouter/meta-llama/llama-3.1-8b") ]
  end

  def gpt
    models.first
  end

  def llama
    models.last
  end

  # A result whose diagnosis comes from the real Diagnosis, so the evidence
  # has the shape the report reads; `judge:` adds the judge's refinement.
  def result(scenario, spec, replay, score: 1.0, judge: nil)
    scores = { "response_present" => replay.answer.present? ? 1.0 : 0.0 }
    diagnosis = Diagnosis.call(scenario: scenario, replay: replay, scores: scores, score: score, available_tools: AVAILABLE)&.to_h
    if diagnosis && judge
      diagnosis["judge"] = judge
      diagnosis["recommendation"] = judge["recommendation"] if judge["recommendation"]
    end
    Result.new(scenario: scenario, spec: spec, replay: replay, scores: scores, score: score,
               status: replay.errored? ? "errored" : (diagnosis ? "failed" : "passed"), diagnosis: diagnosis)
  end

  def grouped(key, prompt, group, name)
    Scenario.from_hash({ "key" => key, "prompt" => prompt, "expectations" => { "tools" => [ "inbox_status" ] } }, group: group, group_name: name)
  end

  # Three named groups and an ungrouped scenario under two models. Orders
  # passes fully under llama and half under gpt; help has a result under gpt
  # alone; experimental fails under gpt and errors under llama; the
  # ungrouped scenario passes under gpt alone.
  def gated_results
    lookup = grouped("order_lookup", "Where is order ABC-123?", "orders", "Order support")
    status = grouped("order_status", "Has order ABC-123 shipped?", "orders", "Order support")
    cancel = grouped("help_cancel", "How do I cancel my order?", "help", "Product help")
    experiment = grouped("exp_1", "Draft a reply in the customer's tone.", "experimental", "Experimental")
    ping = scenario("ping", "Are you there?", group: nil, tools: [ "inbox_status" ])
    called = [ { "name" => "inbox_status" } ]

    [
      result(lookup, gpt, replay(answer: "It shipped on Monday.", tool_calls: called)),
      result(lookup, llama, replay(answer: "Shipped Monday.", tool_calls: called)),
      result(status, gpt, replay(answer: "Probably.", tool_calls: called), score: 0.5),
      result(status, llama, replay(answer: "Yes, on Monday.", tool_calls: called)),
      result(cancel, gpt, replay(answer: "From the order page.", tool_calls: called)),
      result(experiment, gpt, replay(answer: "Dear customer.", tool_calls: called), score: 0.5),
      result(experiment, llama, ActiveAgent::Evals::Replay.failed(RuntimeError.new("provider down")), score: nil),
      result(ping, gpt, replay(answer: "Yes.", tool_calls: called))
    ]
  end

  # The gated results under THRESHOLDS: orders under gpt and gpt's All row
  # are the gates not met.
  def gated_report(**options)
    Report.new(results: gated_results, models: models, pass_thresholds: THRESHOLDS, **options)
  end

  # The gated results that passed, under the same bars: every gate met.
  def passing_report
    Report.new(results: gated_results.select(&:passed?), models: models, pass_thresholds: THRESHOLDS)
  end
end
