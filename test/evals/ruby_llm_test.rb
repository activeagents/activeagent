# frozen_string_literal: true

require "test_helper"
require_relative "evals_test_support"
require "active_agent/evals/ruby_llm"

# The RubyLLM glue: a judge that asks a RubyLLM-shaped chat, and a replay built
# from the messages an `acts_as_chat` conversation stored. No network — the
# chat is a stand-in that records what it was asked and answers from a script.
class EvalsRubyLLMTest < ActiveSupport::TestCase
  include EvalsTestSupport

  # Stands in for `RubyLLM` or a `RubyLLM.context`: records every `chat` call
  # and answers each `ask` with the next scripted reply.
  class FakeContext
    Chat = Struct.new(:context, :options) do
      def with_instructions(instructions)
        context.instructions << instructions
        self
      end

      def ask(prompt)
        context.prompts << prompt
        Struct.new(:content).new(context.replies.shift || "{}")
      end
    end

    attr_reader :chats, :instructions, :prompts, :replies

    def initialize(*replies)
      @replies = replies
      @chats = []
      @instructions = []
      @prompts = []
    end

    def chat(**options)
      @chats << options
      Chat.new(self, options)
    end
  end

  # RubyLLM 1.x `acts_as_chat` shapes: a message record with token columns and
  # a has_many of tool call records with integer ids, matched from a tool
  # message's `tool_call_id` foreign key.
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

  def test_judge_asks_a_chat_on_the_context_with_the_model_and_provider
    context = FakeContext.new('{"score": 0.8}')
    judge = ActiveAgent::Evals::RubyLLM.judge(label: "judge", model: "gpt-5-mini", provider: "openai", context: context,
                                              temperature: 0)

    score = judge.score_task(scenario: scenario, answer: "Alice changed it.")

    assert_equal 0.8, score
    assert_equal [ { model: "gpt-5-mini", provider: :openai, assume_model_exists: true, temperature: 0 } ], context.chats
    assert_equal [ ActiveAgent::Evals::Judge::SCORE_INSTRUCTIONS ], context.instructions
    assert_includes context.prompts.first, "Alice changed it."
  end

  def test_judge_can_be_told_to_check_the_model_registry
    context = FakeContext.new('{"score": 1}')
    judge = ActiveAgent::Evals::RubyLLM.judge(label: "judge", model: "gpt-5-mini", provider: :openai, context: context,
                                              assume_model_exists: false)

    judge.score_task(scenario: scenario, answer: "Alice changed it.")

    assert_equal false, context.chats.first[:assume_model_exists]
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

  def test_judge_failures_degrade_like_any_other_judge
    context = Object.new
    context.define_singleton_method(:chat) { |**| raise IOError, "connection refused" }
    judge = ActiveAgent::Evals::RubyLLM.judge(label: "judge", model: "m", provider: :openai, context: context)

    assert_nil judge.score_task(scenario: scenario, answer: "Alice changed it.")
  end

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
    ], replay.tool_calls
    assert_equal 250, replay.input_tokens
    assert_equal 50, replay.output_tokens
    assert_equal 1_234, replay.duration_ms
    assert_equal({ "chat_id" => 5 }, replay.metadata)
    assert_not replay.errored?
  end

  def test_replay_reads_a_ruby_llm_2_conversation_with_symbol_roles
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
    assert_equal %w[lookup_user find_records], replay.tool_names
    assert_equal [ false, true ], replay.tool_calls.map { |call| call["error"] }
    assert_equal '{"code"=>500}', replay.failed_tool_calls.first["detail"]
    assert_equal 100, replay.input_tokens
    assert_equal 10, replay.output_tokens
  end

  def test_replay_reads_ruby_llm_message_values
    messages = [
      ::RubyLLM::Message.new(role: :user, content: "Where is order ABC-123?"),
      ::RubyLLM::Message.new(role: :assistant, content: "", input_tokens: 30, output_tokens: 4,
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
    assert_equal 80, replay.input_tokens
    assert_equal 16, replay.output_tokens
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
    assert_equal 0, replay.total_tokens
    assert_equal [], replay.tool_calls
  end
end
