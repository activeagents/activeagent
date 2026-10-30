# frozen_string_literal: true

require "test_helper"
require "active_agent/evals/jev"
require_relative "evals_test_support"

# The Jev judge against the wire format its Client assumes, every request
# stubbed: a score is one Score question, a verdict's winner one Choice over
# the compared labels, and the language tasks go to the text judge or nowhere.
class EvalsJevTest < ActiveSupport::TestCase
  include EvalsTestSupport
  include WebMock::API

  ENDPOINT = "https://api.typesafe.ai/v1/systemone"
  KEY = "ts-test-0000"

  SUMMARIES = {
    "gpt-5-mini" => { "pass_rate" => 90.0, "avg_score" => 0.91, "avg_duration_ms" => 1200, "cost" => 0.12 },
    "ollama/qwen3:8b" => { "pass_rate" => 60.0, "avg_score" => 0.7, "faults" => { "low_quality" => 2 } }
  }.freeze

  # Cleared around every test so a key in the developer's environment cannot
  # decide the outcome.
  setup { @previous_key = ENV.delete("TYPESAFE_API_KEY") }
  teardown { ENV["TYPESAFE_API_KEY"] = @previous_key }

  # =====================================================================
  # Scores
  # =====================================================================

  test "a score call sends one Score question with the bearer key and returns the score" do
    stub_jev({ "score" => { "value" => 0.83, "probability" => 0.81, "confidence" => 0.9 } })

    assert_equal 0.83, jev_judge.score_task(scenario: scenario, answer: "Alice changed it on Monday.")

    assert_requested(:post, ENDPOINT, headers: { "Authorization" => "Bearer #{KEY}", "Content-Type" => "application/json" }) do |request|
      body = JSON.parse(request.body)
      question = body.fetch("questions").fetch("score")
      assert_equal "jev-latest", body["model"]
      assert_includes body["state"], "Who changed the shipping policy?"
      assert_includes body["state"], "Alice changed it on Monday."
      assert_equal %w[score], body["questions"].keys
      assert_equal "score", question["type"]
      assert_equal [ 0, 1 ], question.values_at("min", "max")
      true
    end
  end

  test "a score outside the scale is clamped" do
    stub_jev({ "score" => { "value" => 1.4 } })

    assert_equal 1.0, jev_judge.score_task(scenario: scenario, answer: "Alice did.")
  end

  test "a score answered under another field name, as a list, as text, is still read" do
    stub_request(:post, ENDPOINT).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { "results" => [ { "name" => "score", "score" => "0.5" } ] }.to_json
    )

    assert_equal 0.5, jev_judge.score_task(scenario: scenario, answer: "Alice did.")
  end

  test "a score call never goes to the text judge" do
    stub_jev({ "score" => { "value" => 0.6 } })
    calls = []

    assert_equal 0.6, jev_judge(text_judge: text_judge('{"score": 0.1}', calls)).score_task(scenario: scenario, answer: "Alice did.")
    assert_empty calls
  end

  # =====================================================================
  # Verdicts
  # =====================================================================

  test "a verdict call sends a Choice over the compared labels and returns the winner" do
    stub_jev({ "winner" => { "choice" => "ollama/qwen3:8b", "probability" => 0.81 } })

    verdict = jev_judge.verdict(SUMMARIES, instructions: "Answer order questions.")

    assert_equal({ "winner" => "ollama/qwen3:8b", "rationale" => "Chosen by Jev with probability 0.81." }, verdict)
    assert_requested(:post, ENDPOINT) do |request|
      body = JSON.parse(request.body)
      question = body.fetch("questions").fetch("winner")
      assert_includes body["state"], "Results per model:"
      assert_equal "choice", question["type"]
      assert_equal [ "gpt-5-mini", "ollama/qwen3:8b" ], question["options"]
      true
    end
  end

  test "the verdict's rationale comes from the text judge when there is one" do
    stub_jev({ "winner" => { "value" => "ollama/qwen3:8b", "probability" => 0.81 } })
    calls = []
    judge = jev_judge(text_judge: text_judge('{"winner": "gpt-5-mini", "rationale": "Nine of ten passed."}', calls))

    verdict = judge.verdict(SUMMARIES, instructions: "Answer order questions.")

    assert_equal({ "winner" => "ollama/qwen3:8b", "rationale" => "Nine of ten passed." }, verdict)
    assert_equal [ :verdict ], calls.map(&:first)
    assert_equal ActiveAgent::Evals::Judge::VERDICT_INSTRUCTIONS, calls.first[1]
    assert_includes calls.first[2], "Results per model:"
  end

  test "a verdict whose choice is not a compared label is discarded" do
    stub_jev({ "winner" => { "value" => "gpt-5", "probability" => 0.5 } })
    calls = []

    assert_nil jev_judge(text_judge: text_judge("{}", calls)).verdict(SUMMARIES)
    assert_empty calls, "no rationale was asked for a discarded winner"
  end

  # =====================================================================
  # Recommendations
  # =====================================================================

  test "a recommendation is delegated to the text judge" do
    calls = []
    judge = jev_judge(text_judge: text_judge('{"recommendation": "Say when it shipped."}', calls))

    recommendation = judge.recommend(scenario: scenario, replay: replay, diagnosis: diagnosis)

    assert_equal({ "recommendation" => "Say when it shipped." }, recommendation)
    assert_equal [ :recommend ], calls.map(&:first)
    assert_equal ActiveAgent::Evals::Judge::RECOMMEND_INSTRUCTIONS, calls.first[1]
    assert_not_requested :post, ENDPOINT
  end

  test "a recommendation without a text judge is nil and costs no request" do
    assert_nil jev_judge.recommend(scenario: scenario, replay: replay, diagnosis: diagnosis)
    assert_not_requested :post, ENDPOINT
  end

  # =====================================================================
  # Failures
  # =====================================================================

  test "an HTTP 401 makes the call nil and the error names the key variable, never the key" do
    stub_request(:post, ENDPOINT).to_return(status: 401, body: { "error" => "bad key #{KEY}" }.to_json)

    assert_nil jev_judge.score_task(scenario: scenario, answer: "Alice did.")

    error = assert_raises(ActiveAgent::Evals::Jev::Error) { client.score("state", "question") }
    assert_includes error.message, "HTTP 401"
    assert_includes error.message, "TYPESAFE_API_KEY"
    assert_includes error.message, ENDPOINT
    assert_not_includes error.message, KEY
  end

  test "a timeout makes the call nil" do
    stub_request(:post, ENDPOINT).to_timeout

    assert_nil jev_judge.score_task(scenario: scenario, answer: "Alice did.")
  end

  test "a body that is not JSON is an error naming the endpoint and not the body" do
    stub_request(:post, ENDPOINT).to_return(status: 200, body: "<html>maintenance</html>")

    error = assert_raises(ActiveAgent::Evals::Jev::Error) { client.score("state", "question") }
    assert_includes error.message, ENDPOINT
    assert_includes error.message, "invalid JSON"
    assert_not_includes error.message, "maintenance"
    assert_nil jev_judge.score_task(scenario: scenario, answer: "Alice did.")
  end

  test "an answer without the question's decision is an error" do
    stub_jev({ "other" => { "value" => 0.5 } })

    error = assert_raises(ActiveAgent::Evals::Jev::Error) { client.score("state", "question") }
    assert_includes error.message, "without a decision for score"
  end

  test "building a judge without a key raises" do
    error = assert_raises(ArgumentError) { ActiveAgent::Evals::Jev.judge(label: "jev-latest") }
    assert_includes error.message, "TYPESAFE_API_KEY"
  end

  # =====================================================================
  # Usage and routing
  # =====================================================================

  test "on_usage receives the input tokens of each answered call" do
    stub_jev({ "score" => { "value" => 0.7 } }, usage: { "input_tokens" => 412 })
    usages = []

    jev_judge(on_usage: ->(usage) { usages << usage }).score_task(scenario: scenario, answer: "Alice did.")

    assert_equal [ { "kind" => "score", "model" => "jev-1.13", "input_tokens" => 412, "output_tokens" => 0, "cost" => nil } ], usages
  end

  test "on_usage reports nil input tokens when the response has no usage" do
    stub_jev({ "score" => { "value" => 0.7 } }, usage: nil)
    usages = []

    jev_judge(on_usage: ->(usage) { usages << usage }).score_task(scenario: scenario, answer: "Alice did.")

    assert_nil usages.first["input_tokens"]
  end

  test "an on_usage error is logged and the grade kept" do
    stub_jev({ "score" => { "value" => 0.7 } })

    assert_equal 0.7, jev_judge(on_usage: ->(_usage) { raise "meter down" }).score_task(scenario: scenario, answer: "Alice did.")
  end

  test "the key is read from TYPESAFE_API_KEY and a base_url routes the request elsewhere" do
    ENV["TYPESAFE_API_KEY"] = "ts-from-env"
    stub_request(:post, "https://jev.example.test/proxy/v1/systemone").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { "answers" => { "score" => { "value" => 0.9 } } }.to_json
    )

    judge = ActiveAgent::Evals::Jev.judge(label: "jev", model: "jev-preview", base_url: "https://jev.example.test/proxy/")

    assert_equal 0.9, judge.score_task(scenario: scenario, answer: "Alice did.")
    assert_requested(:post, "https://jev.example.test/proxy/v1/systemone", headers: { "Authorization" => "Bearer ts-from-env" }) do |request|
      assert_equal "jev-preview", JSON.parse(request.body)["model"]
      true
    end
    assert_not_requested :post, ENDPOINT
  end

  private

  def jev_judge(**options)
    ActiveAgent::Evals::Jev.judge(label: "jev-latest", api_key: KEY, **options)
  end

  def client
    ActiveAgent::Evals::Jev::Client.new(api_key: KEY)
  end

  # A text judge that records every call it is asked, as `[kind, instructions, prompt]`.
  def text_judge(reply, calls)
    ActiveAgent::Evals::Judge.new(label: "text") do |instructions:, prompt:, kind:|
      calls << [ kind, instructions, prompt ]
      reply
    end
  end

  def diagnosis
    ActiveAgent::Evals::Diagnosis::Result.new(fault: "low_quality", summary: "s", recommendation: "r", evidence: {})
  end

  def stub_jev(answers, usage: { "input_tokens" => 321 })
    body = { "model" => "jev-1.13", "answers" => answers }
    body["usage"] = usage if usage
    stub_request(:post, ENDPOINT).to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json)
  end
end
