# frozen_string_literal: true

require "test_helper"
require "active_agent/evals/jev"
require_relative "evals_test_support"

# The Jev judge against the System One protocol as OpenJevX serves it, every
# request stubbed: a score is one Score question over described levels, a
# verdict's winner one Choice over the compared labels with their results,
# and the language tasks go to the text judge or nowhere.
class EvalsJevTest < ActiveSupport::TestCase
  include EvalsTestSupport
  include WebMock::API

  Jev = ActiveAgent::Evals::Jev

  ENDPOINT = "https://api.typesafe.ai/v1/systemone"
  LOCAL_ENDPOINT = "#{Jev::OPENJEVX_BASE_URL}/v1/systemone".freeze
  KEY = "ts-test-0000"

  SUMMARIES = {
    "gpt-5-mini" => { "pass_rate" => 90.0, "avg_score" => 0.91, "avg_duration_ms" => 1200, "cost" => 0.12 },
    "ollama/qwen3:8b" => { "pass_rate" => 60.0, "avg_score" => 0.7, "faults" => { "low_quality" => 2 } }
  }.freeze

  # An OpenJevX score answer: the expected level 3.2 of 0..4, so 0.8.
  SCORE_ANSWER = {
    "type" => "score", "score" => 3.2,
    "probabilities" => { "0" => 0.02, "1" => 0.08, "2" => 0.2, "3" => 0.25, "4" => 0.45 }, "confidence" => 0.45
  }.freeze
  CHOICE_ANSWER = {
    "type" => "choice", "choice" => "ollama/qwen3:8b",
    "probabilities" => { "gpt-5-mini" => 0.19, "ollama/qwen3:8b" => 0.81 }, "confidence" => 0.81
  }.freeze

  # Cleared around every test so a key in the developer's environment cannot
  # decide the outcome.
  setup { @previous_key = ENV.delete("TYPESAFE_API_KEY") }
  teardown { ENV["TYPESAFE_API_KEY"] = @previous_key }

  # =====================================================================
  # Scores
  # =====================================================================

  test "a score call sends one Score question over the described levels and returns the expected level as 0..1" do
    stub_jev({ "score" => SCORE_ANSWER })

    assert_in_delta 0.8, jev_judge.score_task(scenario: scenario, answer: "Alice changed it on Monday."), 1e-9

    assert_requested(:post, ENDPOINT, headers: { "Authorization" => "Bearer #{KEY}", "Content-Type" => "application/json" }) do |request|
      body = JSON.parse(request.body)
      question = body.fetch("questions").fetch("score")
      assert_equal "jev-latest", body["model"]
      assert_includes body["state"], "Who changed the shipping policy?"
      assert_includes body["state"], "Alice changed it on Monday."
      assert_not_includes body["state"], "Respond only with JSON", "the request for JSON is for a language model"
      assert_equal %w[score], body["questions"].keys
      assert_equal "score", question["type"]
      assert_equal Jev::SCORE_QUESTION, question["instructions"]
      assert_equal Jev::SCORE_LEVELS, question["criteria"]
      true
    end
  end

  test "a level beyond the scale is clamped" do
    stub_jev({ "score" => SCORE_ANSWER.merge("score" => 5.5) })

    assert_equal 1.0, jev_judge.score_task(scenario: scenario, answer: "Alice did.")
  end

  test "a score answered under another field name, as a list, as text, is still read" do
    stub_request(:post, ENDPOINT).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { "results" => [ { "name" => "score", "value" => "2" } ] }.to_json
    )

    assert_equal 0.5, jev_judge.score_task(scenario: scenario, answer: "Alice did.")
  end

  test "a score call never goes to the text judge" do
    stub_jev({ "score" => SCORE_ANSWER })
    calls = []

    assert_in_delta 0.8, jev_judge(text_judge: text_judge('{"score": 0.1}', calls)).score_task(scenario: scenario, answer: "Alice did."), 1e-9
    assert_empty calls
  end

  # =====================================================================
  # Verdicts
  # =====================================================================

  test "a verdict call sends a Choice over the compared labels, each described by its results, and returns the winner" do
    stub_jev({ "winner" => CHOICE_ANSWER })

    verdict = jev_judge.verdict(SUMMARIES, instructions: "Answer order questions.")

    assert_equal({ "winner" => "ollama/qwen3:8b", "rationale" => "Chosen by Jev with probability 0.81." }, verdict)
    assert_requested(:post, ENDPOINT) do |request|
      body = JSON.parse(request.body)
      question = body.fetch("questions").fetch("winner")
      assert_includes body["state"], "Results per model:"
      assert_equal "choice", question["type"]
      assert_equal Jev::VERDICT_QUESTION, question["instructions"]
      assert_equal [ "gpt-5-mini", "ollama/qwen3:8b" ], question["criteria"].keys
      assert_match(/\Apass rate 90\.0%, mean score 0\.91, avg latency 1200ms, cost \$0\.12\z/, question["criteria"]["gpt-5-mini"])
      assert_includes question["criteria"]["ollama/qwen3:8b"], "faults: low_quality×2"
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
    stub_jev({ "winner" => CHOICE_ANSWER.merge("choice" => "gpt-5") })
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

    error = assert_raises(Jev::Error) { client.score("state", "question", Jev::SCORE_LEVELS) }
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

    error = assert_raises(Jev::Error) { client.score("state", "question", Jev::SCORE_LEVELS) }
    assert_includes error.message, ENDPOINT
    assert_includes error.message, "invalid JSON"
    assert_not_includes error.message, "maintenance"
    assert_nil jev_judge.score_task(scenario: scenario, answer: "Alice did.")
  end

  test "an answer without the question's decision, or without a number for a score, is an error" do
    stub_jev({ "other" => SCORE_ANSWER })
    error = assert_raises(Jev::Error) { client.score("state", "question", Jev::SCORE_LEVELS) }
    assert_includes error.message, "without a decision for score"

    stub_jev({ "score" => { "type" => "score", "score" => "high" } })
    error = assert_raises(Jev::Error) { client.score("state", "question", Jev::SCORE_LEVELS) }
    assert_includes error.message, "without a number"
  end

  test "building a judge for the hosted endpoint without a key raises" do
    error = assert_raises(ArgumentError) { Jev.judge(label: "jev-latest") }
    assert_includes error.message, "TYPESAFE_API_KEY"
  end

  # =====================================================================
  # A server of your own
  # =====================================================================

  test "a local OpenJevX needs no key and is sent no model" do
    stub_request(:post, LOCAL_ENDPOINT).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { "answers" => { "score" => SCORE_ANSWER } }.to_json
    )
    usages = []
    judge = Jev.judge(label: "openjevx", base_url: Jev::OPENJEVX_BASE_URL, on_usage: ->(usage) { usages << usage })

    assert_in_delta 0.8, judge.score_task(scenario: scenario, answer: "Alice did."), 1e-9

    assert_requested(:post, LOCAL_ENDPOINT) do |request|
      assert_not request.headers.key?("Authorization"), "no key was configured, so none is sent"
      assert_not JSON.parse(request.body).key?("model"), "a server of your own serves one model"
      true
    end
    assert_equal [ { "kind" => "score", "model" => nil, "input_tokens" => nil, "output_tokens" => 0, "cost" => nil } ], usages
  end

  # =====================================================================
  # Usage and routing
  # =====================================================================

  test "on_usage receives the input tokens of each answered call" do
    stub_jev({ "score" => SCORE_ANSWER }, usage: { "input_tokens" => 412 })
    usages = []

    jev_judge(on_usage: ->(usage) { usages << usage }).score_task(scenario: scenario, answer: "Alice did.")

    assert_equal [ { "kind" => "score", "model" => "jev-1.13", "input_tokens" => 412, "output_tokens" => 0, "cost" => nil } ], usages
  end

  test "on_usage reports nil input tokens when the response has no usage" do
    stub_jev({ "score" => SCORE_ANSWER })
    usages = []

    jev_judge(on_usage: ->(usage) { usages << usage }).score_task(scenario: scenario, answer: "Alice did.")

    assert_nil usages.first["input_tokens"]
  end

  test "an on_usage error is logged and the grade kept" do
    stub_jev({ "score" => SCORE_ANSWER })

    assert_in_delta 0.8, jev_judge(on_usage: ->(_usage) { raise "meter down" }).score_task(scenario: scenario, answer: "Alice did."), 1e-9
  end

  test "the key is read from TYPESAFE_API_KEY and a base_url routes the request elsewhere" do
    ENV["TYPESAFE_API_KEY"] = "ts-from-env"
    stub_request(:post, "https://jev.example.test/proxy/v1/systemone").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { "answers" => { "score" => SCORE_ANSWER.merge("score" => 4) } }.to_json
    )

    judge = Jev.judge(label: "jev", model: "jev-preview", base_url: "https://jev.example.test/proxy/")

    assert_equal 1.0, judge.score_task(scenario: scenario, answer: "Alice did.")
    assert_requested(:post, "https://jev.example.test/proxy/v1/systemone", headers: { "Authorization" => "Bearer ts-from-env" }) do |request|
      assert_equal "jev-preview", JSON.parse(request.body)["model"]
      true
    end
    assert_not_requested :post, ENDPOINT
  end

  private

  def jev_judge(**options)
    Jev.judge(label: "jev-latest", api_key: KEY, **options)
  end

  def client
    Jev::Client.new(api_key: KEY)
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

  # A hosted answer: the model that answered, the answers, and usage when given.
  def stub_jev(answers, usage: nil)
    body = { "model" => "jev-1.13", "answers" => answers }
    body["usage"] = usage if usage
    stub_request(:post, ENDPOINT).to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json)
  end
end
