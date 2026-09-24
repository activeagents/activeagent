# frozen_string_literal: true

# The RubyLLM glue: a judge that asks a RubyLLM-shaped chat, and a replay built
# from the messages a RubyLLM conversation produced. No network — the chat is a
# stand-in that records what it was asked and answers from a script. What real
# RubyLLM messages and records replay to is ruby_llm_conversation_test.rb.
#
# These cases load the real ruby_llm gem, so ruby_llm_test.rb runs them in a
# process of their own:
#
#   ruby -Ilib -Itest test/evals/support/ruby_llm_glue_cases.rb
require "minitest/autorun"
require "active_agent/evals/ruby_llm"
require_relative "../evals_test_support"

class EvalsRubyLLMGlueCases < Minitest::Test
  include EvalsTestSupport

  # Stands in for `RubyLLM` or a `RubyLLM.context`: records every `chat` call
  # and answers each `ask` with the next scripted reply.
  class FakeContext
    Reply = Struct.new(:content, :tokens, :model, :cost)

    Chat = Struct.new(:context, :options) do
      def with_temperature(temperature)
        context.temperatures << temperature
        self
      end

      def with_instructions(instructions)
        context.instructions << instructions
        self
      end

      def ask(prompt)
        context.prompts << prompt
        Reply.new(context.replies.shift || "{}", Tokens.new(12, 3), "judge-model-2026", 0.25)
      end
    end

    attr_reader :chats, :instructions, :prompts, :replies, :temperatures

    def initialize(*replies)
      @replies = replies
      @chats = []
      @instructions = []
      @prompts = []
      @temperatures = []
    end

    def chat(**options)
      @chats << options
      Chat.new(self, options)
    end
  end

  # RubyLLM 1.x `acts_as_chat` shapes, read without `to_llm`: a message record
  # with token columns and a has_many of tool call records with integer ids,
  # matched from a tool message's `tool_call_id` foreign key.
  Message = Struct.new(:role, :content, :tool_calls, :tool_call_id, :input_tokens, :output_tokens, keyword_init: true) do
    def initialize(role:, content: nil, tool_calls: [], tool_call_id: nil, input_tokens: nil, output_tokens: nil)
      super
    end
  end
  ToolCall = Struct.new(:id, :name, :arguments, keyword_init: true)

  # RubyLLM 2.x shapes: `tokens` is an object with `input`/`output`, and
  # `tool_calls` is a Hash keyed by the provider's call id.
  Tokens = Struct.new(:input, :output)
  Message2 = Struct.new(:role, :content, :tool_calls, :tool_call_id, :tokens, keyword_init: true)

  # A relation: only `to_a` is called on it.
  class Relation
    def initialize(records) = @records = records
    def to_a = @records
  end

  # A record that stores the conversation its own way and hands back a
  # RubyLLM::Message through `to_llm`, as `acts_as_message` does.
  class Record
    def initialize(message) = @message = message
    def to_llm = @message
    def tool_call_id = raise(NoMethodError, "records keep this elsewhere")
  end

  # --- judge ---------------------------------------------------------------

  def test_judge_asks_a_chat_on_the_context_with_the_model_and_provider
    context = FakeContext.new('{"score": 0.8}')
    judge = ActiveAgent::Evals::RubyLLM.judge(label: "judge", model: "gpt-5-mini", provider: "openai", context: context,
                                              temperature: 0)

    score = judge.score_task(scenario: scenario, answer: "Alice changed it.")

    assert_equal 0.8, score
    assert_equal [ { model: "gpt-5-mini", provider: :openai, assume_model_exists: true } ], context.chats
    assert_equal [ 0 ], context.temperatures
    assert_equal [ ActiveAgent::Evals::Judge::SCORE_INSTRUCTIONS ], context.instructions
    assert_includes context.prompts.first, "Alice changed it."
  end

  def test_judge_can_be_told_to_check_the_model_registry
    context = FakeContext.new('{"score": 1}')
    judge = ActiveAgent::Evals::RubyLLM.judge(label: "judge", model: "gpt-5-mini", provider: :openai, context: context,
                                              assume_model_exists: false)

    judge.score_task(scenario: scenario, answer: "Alice changed it.")

    assert_equal false, context.chats.first[:assume_model_exists]
    assert_empty context.temperatures, "no temperature is set unless one is given"
  end

  # A keyword RubyLLM::Chat.new does not take would raise inside every judge
  # call, where Judge swallows it and the run silently falls back to rules.
  def test_judge_refuses_a_chat_option_that_ruby_llm_chat_does_not_take
    error = assert_raises(ArgumentError) do
      ActiveAgent::Evals::RubyLLM.judge(label: "judge", model: "m", provider: :openai, context: FakeContext.new,
                                        max_tokens: 50)
    end

    assert_match(/does not take :max_tokens/, error.message)
    assert_match(/configure:/, error.message)
  end

  def test_judge_passes_chat_options_ruby_llm_chat_takes
    accepted = ::RubyLLM::Chat.instance_method(:initialize).parameters.filter_map { |type, name| name if type == :key } -
               ActiveAgent::Evals::RubyLLM::JUDGE_CHAT_KEYWORDS
    skip "RubyLLM::Chat.new #{::RubyLLM::VERSION} takes no other keywords" if accepted.empty?

    context = FakeContext.new('{"score": 1}')
    judge = ActiveAgent::Evals::RubyLLM.judge(label: "judge", model: "m", provider: :openai, context: context,
                                              accepted.first => :value)
    judge.score_task(scenario: scenario, answer: "Alice changed it.")

    assert_equal :value, context.chats.first[accepted.first]
  end

  def test_judge_configures_each_chat_before_asking_it
    configured = []
    context = FakeContext.new('{"score": 0.5}', '{"score": 0.5}')
    judge = ActiveAgent::Evals::RubyLLM.judge(label: "judge", model: "m", provider: :openai, context: context,
                                              configure: ->(chat) { configured << chat.options })

    2.times { judge.score_task(scenario: scenario, answer: "Alice changed it.") }

    assert_equal 2, configured.size
  end

  def test_judge_traces_each_call_through_the_correlation_under_its_kind
    tracer_calls = []
    tracer = lambda do |name, action:, attributes:, on_trace:, &block|
      tracer_calls << [ name, action ]
      on_trace&.call(Struct.new(:trace_id).new("trace-#{tracer_calls.size}"))
      block.call
    end
    correlation = ActiveAgent::Evals::Correlation.new(agent_name: "SupportAgent", tracer: tracer)
    context = FakeContext.new('{"score": 0.5}', '{"winner": "test-model", "rationale": "only one"}')
    judge = ActiveAgent::Evals::RubyLLM.judge(label: "judge", model: "m", provider: :openai, context: context,
                                              correlation: correlation)

    metadata = nil
    correlation.with_run do |run|
      metadata = run
      judge.score_task(scenario: scenario, answer: "Alice changed it.")
      judge.verdict({ "test-model" => { "pass_rate" => 100 } })
    end

    assert_equal [ [ "SupportAgentJudge", "score" ], [ "SupportAgentJudge", "verdict" ] ], tracer_calls
    assert_equal %w[trace-1 trace-2], metadata["judge_trace_ids"]
  end

  def test_judge_reports_each_calls_usage
    usage = []
    context = FakeContext.new('{"score": 0.5}')
    judge = ActiveAgent::Evals::RubyLLM.judge(label: "judge", model: "m", provider: :openai, context: context,
                                              on_usage: ->(entry) { usage << entry })

    judge.score_task(scenario: scenario, answer: "Alice changed it.")

    assert_equal [ { "kind" => "score", "model" => "judge-model-2026", "input_tokens" => 12, "output_tokens" => 3,
                     "cost" => 0.25 } ], usage
  end

  def test_a_failing_usage_callback_does_not_cost_the_grade
    context = FakeContext.new('{"score": 0.5}')
    judge = ActiveAgent::Evals::RubyLLM.judge(label: "judge", model: "m", provider: :openai, context: context,
                                              on_usage: ->(_) { raise "meter down" })

    assert_equal 0.5, judge.score_task(scenario: scenario, answer: "Alice changed it.")
  end

  def test_judge_failures_degrade_like_any_other_judge
    context = Object.new
    context.define_singleton_method(:chat) { |**| raise IOError, "connection refused" }
    judge = ActiveAgent::Evals::RubyLLM.judge(label: "judge", model: "m", provider: :openai, context: context)

    assert_nil judge.score_task(scenario: scenario, answer: "Alice changed it.")
  end

  # --- replay ----------------------------------------------------------------

  def test_replay_reads_a_ruby_llm_1_conversation
    messages = [
      Message.new(role: "user", content: "Who changed the biography?"),
      Message.new(role: "assistant", content: nil, input_tokens: 100, output_tokens: 20, tool_calls: [
        ToolCall.new(id: 12, name: "find_records", arguments: { "type" => "biography" }),
        ToolCall.new(id: 11, name: "lookup_user", arguments: { "name" => "Alice" })
      ]),
      Message.new(role: "tool", content: '{"error":"MCP tool find_records timed out"}', tool_call_id: 12),
      Message.new(role: "tool", content: '{"id": 7, "name": "Alice"}', tool_call_id: 11),
      Message.new(role: "assistant", content: "Alice changed it on Monday.", input_tokens: 150, output_tokens: 30)
    ]

    replay = ActiveAgent::Evals::RubyLLM.replay(messages, duration_ms: 1_234, metadata: { "chat_id" => 5 })

    assert_equal "Alice changed it on Monday.", replay.answer
    assert_equal [
      { "name" => "lookup_user", "arguments" => { "name" => "Alice" }, "error" => false },
      { "name" => "find_records", "arguments" => { "type" => "biography" }, "error" => true,
        "detail" => "MCP tool find_records timed out" }
    ], replay.tool_calls, "record primary keys are creation order"
    assert_equal 250, replay.input_tokens
    assert_equal 50, replay.output_tokens
    assert_equal 1_234, replay.duration_ms
    assert_equal({ "chat_id" => 5 }, replay.metadata)
    assert_nil replay.cost, "nothing here is priced"
    refute replay.errored?
  end

  def test_replay_keeps_the_order_calls_were_made_in_and_encodes_structured_errors_as_json
    messages = [
      Message2.new(role: :user, content: "Who changed the biography?"),
      Message2.new(role: :assistant, tokens: Tokens.new(40, 5), tool_calls: {
        "call_b" => ToolCall.new(id: "call_b", name: "find_records", arguments: {}),
        "call_a" => ToolCall.new(id: "call_a", name: "lookup_user", arguments: {})
      }),
      Message2.new(role: :tool, content: "not json", tool_call_id: "call_a"),
      Message2.new(role: :tool, content: '{"error": {"code": 500}}', tool_call_id: "call_b"),
      Message2.new(role: :assistant, content: "Alice.", tokens: Tokens.new(60, 5))
    ]

    replay = ActiveAgent::Evals::RubyLLM.replay(messages)

    assert_equal "Alice.", replay.answer
    assert_equal %w[find_records lookup_user], replay.tool_names, "provider call ids say nothing about order"
    assert_equal [ true, false ], replay.tool_calls.map { |call| call["error"] }
    assert_equal '{"code":500}', replay.failed_tool_calls.first["detail"]
    assert_equal 100, replay.input_tokens
    assert_equal 10, replay.output_tokens
  end

  def test_replay_reads_records_through_to_llm
    messages = [
      Record.new(::RubyLLM::Message.new(role: :user, content: "Where is order ABC-123?")),
      Record.new(::RubyLLM::Message.new(role: :assistant, content: "", input_tokens: 30, output_tokens: 4,
                                        tool_calls: { "c1" => ::RubyLLM::ToolCall.new(id: "c1", name: "lookup_order",
                                                                                       arguments: {}) })),
      Record.new(::RubyLLM::Message.new(role: :tool, content: '{"error": "not found"}', tool_call_id: "c1")),
      Record.new(::RubyLLM::Message.new(role: :assistant, content: "I could not find it.", input_tokens: 50,
                                        output_tokens: 6))
    ]

    replay = ActiveAgent::Evals::RubyLLM.replay(messages)

    assert_equal "I could not find it.", replay.answer
    assert_equal [ { "name" => "lookup_order", "arguments" => {}, "error" => true, "detail" => "not found" } ],
      replay.tool_calls
    assert_equal 80, replay.input_tokens
  end

  def test_replay_reads_ruby_llm_message_values_and_counts_the_cached_prompt
    messages = [
      ::RubyLLM::Message.new(role: :user, content: "Where is order ABC-123?"),
      ::RubyLLM::Message.new(role: :assistant, content: "", input_tokens: 30, output_tokens: 4, **cached_tokens(20),
                             tool_calls: { "c1" => ::RubyLLM::ToolCall.new(id: "c1", name: "lookup_order",
                                                                            arguments: { "number" => "ABC-123" }) }),
      ::RubyLLM::Message.new(role: :tool, content: '{"status": "shipped"}', tool_call_id: "c1"),
      ::RubyLLM::Message.new(role: :assistant, content: "Order ABC-123 shipped on Monday.", input_tokens: 50,
                             output_tokens: 12)
    ]

    replay = ActiveAgent::Evals::RubyLLM.replay(messages)

    assert_equal "Order ABC-123 shipped on Monday.", replay.answer
    assert_equal [ { "name" => "lookup_order", "arguments" => { "number" => "ABC-123" }, "error" => false } ],
      replay.tool_calls
    assert_equal 100, replay.input_tokens, "RubyLLM counts the 20 cached prompt tokens apart from input"
    assert_equal 16, replay.output_tokens
  end

  def test_replay_reads_errors_the_ways_tools_report_them
    detail = ->(content) { tool_result_detail(content) }

    assert_equal "backend timed out", detail.call('{:error=>"backend timed out"}'), "RubyLLM 1.x on Ruby 3.3"
    assert_equal "backend timed out", detail.call('{error: "backend timed out"}'), "RubyLLM 1.x on Ruby 3.4"
    assert_equal "quoted \"x\" café", detail.call({ error: "quoted \"x\" café" }.to_s)
    assert_equal "server said no", detail.call('{"status" => 500, "error" => "server said no"}')
    assert_equal "boom", detail.call({ "error" => "boom" }), "an unserialized Hash"
    assert_equal "Rate limited\nretry later",
      detail.call('{"content": [{"type": "text", "text": "Rate limited"}, {"type": "text", "text": "retry later"}], "isError": true}'),
      "an MCP tool result"
    assert_nil detail.call('{"result": 1, "error": null}')
    assert_nil detail.call('{"error": false}')
    assert_nil detail.call('{"content": [], "isError": false}')
    assert_nil detail.call("{:error=>nil}")
    assert_nil detail.call("the error log is empty")
    assert_operator detail.call({ "error" => "x" * 50_000 }.to_json).bytesize, :<=,
      ActiveAgent::Evals::RubyLLM::DETAIL_LIMIT
  end

  def test_a_conversation_that_stopped_at_a_tool_call_has_no_answer
    messages = [
      ::RubyLLM::Message.new(role: :user, content: "Refund order ABC-123"),
      ::RubyLLM::Message.new(role: :assistant, content: "", input_tokens: 30, output_tokens: 4,
                             tool_calls: { "c1" => ::RubyLLM::ToolCall.new(id: "c1", name: "refund_order", arguments: {}) })
    ]

    replay = ActiveAgent::Evals::RubyLLM.replay(messages)

    assert_nil replay.answer
    assert replay.errored?
    assert_equal "The conversation stopped at a call to refund_order without a final answer", replay.error
    assert_equal [ "refund_order" ], replay.tool_names

    answered = ActiveAgent::Evals::RubyLLM.replay(messages, answer: "Refund pending approval.")
    assert_equal "Refund pending approval.", answered.answer
    refute answered.errored?, "an answer the caller supplies settles it"
  end

  def test_a_conversation_that_stopped_at_a_tool_result_has_no_answer
    messages = [
      Message.new(role: "user", content: "Where is it?"),
      Message.new(role: "assistant", content: "Checking.", tool_calls: [ ToolCall.new(id: 1, name: "lookup_order") ]),
      Message.new(role: "tool", content: '{"status": "shipped"}', tool_call_id: 1)
    ]

    replay = ActiveAgent::Evals::RubyLLM.replay(messages)

    assert_nil replay.answer, "the text beside a tool call is not the answer"
    assert_equal "The conversation stopped at a call to lookup_order without a final answer", replay.error
  end

  def test_replay_sums_what_ruby_llm_priced_and_takes_an_explicit_cost
    priced = Struct.new(:role, :content, :cost)
    messages = [ priced.new("user", "Hi", nil), priced.new("assistant", "Hello", 0.002), priced.new("assistant", "Bye", 0.001) ]

    assert_in_delta 0.003, ActiveAgent::Evals::RubyLLM.replay(messages).cost
    assert_equal 0.5, ActiveAgent::Evals::RubyLLM.replay(messages, cost: 0.5).cost

    messages << priced.new("assistant", "Unpriced", nil)
    assert_nil ActiveAgent::Evals::RubyLLM.replay(messages).cost, "a partial sum would read as the whole cost"
  end

  def test_replay_takes_a_relation_and_an_explicit_answer_and_error
    relation = Relation.new([
      Message.new(role: "user", content: "Hi"),
      Message.new(role: "assistant", content: "Partial", input_tokens: 1, output_tokens: 1)
    ])

    replay = ActiveAgent::Evals::RubyLLM.replay(relation, answer: "Overridden", error: RuntimeError.new("boom"))

    assert_equal "Overridden", replay.answer
    assert_equal "RuntimeError: boom", replay.error
    assert replay.errored?
    assert_equal [], replay.tool_calls
  end

  def test_replay_of_a_conversation_without_an_answer
    replay = ActiveAgent::Evals::RubyLLM.replay([ Message.new(role: "user", content: "Hi") ])

    assert_nil replay.answer
    refute replay.errored?
    assert_equal 0, replay.total_tokens
    assert_equal [], replay.tool_calls
  end

  private

  # The cached-token keyword each RubyLLM generation's Message takes.
  def cached_tokens(count)
    Gem::Version.new(::RubyLLM::VERSION) >= Gem::Version.new("2") ? { cache_read_tokens: count } : { cached_tokens: count }
  end

  def tool_result_detail(content)
    messages = [
      Message2.new(role: :assistant, tool_calls: { "c" => ToolCall.new(id: "c", name: "t", arguments: {}) }),
      Message2.new(role: :tool, content: content, tool_call_id: "c"),
      Message2.new(role: :assistant, content: "done")
    ]
    ActiveAgent::Evals::RubyLLM.replay(messages).tool_calls.first["detail"]
  end
end
