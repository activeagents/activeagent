# frozen_string_literal: true

# The RubyLLM glue: a judge that asks a RubyLLM-shaped chat, a preflight that
# builds a chat per model, and a replay built from the messages a RubyLLM
# conversation produced. No network — the chat is a stand-in that records what
# it was asked and answers from a script, and WebMock refuses every connection
# the case that builds a chat on the real gem could open. What real RubyLLM
# messages and records replay to is ruby_llm_conversation_test.rb.
#
# These cases load the real ruby_llm gem, so ruby_llm_test.rb runs them in a
# process of their own:
#
#   ruby -Ilib -Itest test/evals/support/ruby_llm_glue_cases.rb
require "minitest/autorun"
require "webmock/minitest"
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

  # Stands in for a context holding an OpenAI key only: `chat` records what it
  # was asked, refuses Anthropic the way RubyLLM's provider does, and builds a
  # chat for anyone else.
  class KeyedContext
    attr_reader :chats

    def initialize
      @chats = []
    end

    def chat(**options)
      @chats << options
      raise ::RubyLLM::ConfigurationError, "Anthropic provider is not configured" if options[:provider] == :anthropic

      Object.new
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

  def test_judge_can_verify_its_provider_when_it_is_built
    context = KeyedContext.new

    error = assert_raises(::RubyLLM::ConfigurationError) do
      ActiveAgent::Evals::RubyLLM.judge(label: "judge", model: "claude-sonnet-5", provider: :anthropic, context: context,
                                        verify: true)
    end

    assert_equal missing_key_message("judge", :anthropic, error.cause), error.message
    assert_equal [ { model: "claude-sonnet-5", provider: :anthropic, assume_model_exists: true } ], context.chats,
      "the chat was built once, to verify it, and never asked"

    judge = ActiveAgent::Evals::RubyLLM.judge(label: "judge", model: "gpt-5-mini", provider: :openai, context: context,
                                              verify: true)
    assert_kind_of ActiveAgent::Evals::Judge, judge

    context = KeyedContext.new
    assert_raises(ArgumentError) do
      ActiveAgent::Evals::RubyLLM.judge(label: "judge", model: "claude-sonnet-5", provider: :anthropic, context: context,
                                        verify: true, max_tokens: 50)
    end
    assert_empty context.chats, "the chat options are checked before the provider is"
  end

  def test_judge_stays_lazy_unless_asked_to_verify
    context = KeyedContext.new
    judge = ActiveAgent::Evals::RubyLLM.judge(label: "judge", model: "claude-sonnet-5", provider: :anthropic, context: context)

    assert_empty context.chats, "no chat is built until the first grade"
    assert_nil judge.score_task(scenario: scenario, answer: "Alice changed it."), "the missing key fails the first grade"
    assert_equal 1, context.chats.size
  end

  # --- verify! ---------------------------------------------------------------

  def test_verify_builds_a_chat_per_model_in_order_and_returns_them
    context = KeyedContext.new
    specs = [ spec("gpt-5-mini"), spec("gpt-5") ]

    assert_same specs, ActiveAgent::Evals::RubyLLM.verify!(specs, context: context)
    assert_equal [ { model: "gpt-5-mini", provider: :openai, assume_model_exists: true },
                   { model: "gpt-5", provider: :openai, assume_model_exists: true } ], context.chats
  end

  def test_verify_refuses_the_first_model_whose_provider_has_no_key
    context = KeyedContext.new

    error = assert_raises(::RubyLLM::ConfigurationError) do
      ActiveAgent::Evals::RubyLLM.verify!([ spec("gpt-5-mini"), spec("claude-sonnet-5"), spec("gpt-5") ], context: context)
    end

    assert_equal missing_key_message("claude-sonnet-5", :anthropic, error.cause), error.message
    assert_kind_of ::RubyLLM::ConfigurationError, error.cause
    assert_equal "Anthropic provider is not configured", error.cause.message
    assert_equal %i[openai anthropic], context.chats.map { |chat| chat[:provider] }, "the models after it are not built"
  end

  def test_verify_refuses_a_provider_ruby_llm_does_not_know_before_building_a_chat
    context = KeyedContext.new
    acme = ModelSpec.new(label: "acme/gpt-5-mini", provider: "acme", model: "gpt-5-mini")

    error = assert_raises(::RubyLLM::ConfigurationError) { ActiveAgent::Evals::RubyLLM.verify!([ acme ], context: context) }

    known = ::RubyLLM::Provider.providers.keys.map(&:to_s).sort.join(", ")
    assert_equal "acme/gpt-5-mini runs on acme, which is not a RubyLLM provider; RubyLLM knows #{known}", error.message
    assert_empty context.chats
  end

  def test_verify_refuses_a_provider_outside_the_configured_ones_before_building_a_chat
    context = KeyedContext.new

    error = assert_raises(::RubyLLM::ConfigurationError) do
      ActiveAgent::Evals::RubyLLM.verify!([ spec("claude-sonnet-5") ], context: context, providers: [ "openai" ])
    end
    assert_equal "claude-sonnet-5 runs on anthropic; credentials are configured for openai", error.message
    assert_empty context.chats

    error = assert_raises(::RubyLLM::ConfigurationError) do
      ActiveAgent::Evals::RubyLLM.verify!([ spec("claude-sonnet-5") ], context: context, providers: %i[openai ollama])
    end
    assert_equal "claude-sonnet-5 runs on anthropic; credentials are configured for openai, ollama", error.message

    ActiveAgent::Evals::RubyLLM.verify!([ spec("gpt-5-mini") ], context: context, providers: %i[openai ollama])
    assert_equal [ :openai ], context.chats.map { |chat| chat[:provider] }, "a configured provider's chat is built"

    ActiveAgent::Evals::RubyLLM.verify!([ spec("gpt-5-mini") ], context: context, providers: "openai")
    assert_equal 2, context.chats.size, "one provider name is taken on its own"
  end

  def test_verify_takes_a_single_spec
    context = KeyedContext.new

    assert_equal [ spec("gpt-5-mini") ], ActiveAgent::Evals::RubyLLM.verify!(spec("gpt-5-mini"), context: context)
    assert_equal 1, context.chats.size
  end

  # The real gem: a chat built with assume_model_exists: true sends nothing
  # (WebMock would refuse it), and a provider the context has no key for is
  # refused while RubyLLM instantiates it. RubyLLM reads no API keys from the
  # environment, so the key is written onto a context's configuration.
  def test_verify_against_ruby_llm_itself_sends_nothing_and_refuses_a_provider_without_a_key
    context = ::RubyLLM.context { |config| config.openai_api_key = "sk-placeholder" }
    specs = [ spec("gpt-5-mini") ]

    assert_same specs, ActiveAgent::Evals::RubyLLM.verify!(specs, context: context)

    deepseek = ModelSpec.new(label: "deepseek-chat", provider: "deepseek", model: "deepseek-chat")
    error = assert_raises(::RubyLLM::ConfigurationError) { ActiveAgent::Evals::RubyLLM.verify!([ deepseek ]) }

    assert_equal missing_key_message("deepseek-chat", :deepseek, error.cause), error.message
    assert_kind_of ::RubyLLM::ConfigurationError, error.cause
  end

  # A refusal names only the requirements the context's configuration leaves
  # unset, joined with "and", and calls them an API key only when each one
  # is; with every listed requirement set, RubyLLM's own message says what
  # the provider still wants.
  def test_verify_names_the_requirements_the_context_leaves_unset
    with_provider(:aardvark, requirements: %i[aardvark_api_base aardvark_api_key]) do
      aardvark = ModelSpec.new(label: "aardvark-1", provider: "aardvark", model: "aardvark-1")

      error = assert_raises(::RubyLLM::ConfigurationError) { ActiveAgent::Evals::RubyLLM.verify!(aardvark) }
      assert_equal "aardvark-1 runs on aardvark, which is not configured. Set AARDVARK_API_BASE and AARDVARK_API_KEY.",
        error.message

      context = ::RubyLLM.context { |config| config.aardvark_api_base = "https://aardvark.example" }
      error = assert_raises(::RubyLLM::ConfigurationError) { ActiveAgent::Evals::RubyLLM.verify!(aardvark, context: context) }
      assert_equal "aardvark-1 runs on aardvark, which has no API key. Set AARDVARK_API_KEY.", error.message

      context = ::RubyLLM.context do |config|
        config.aardvark_api_base = "https://aardvark.example"
        config.aardvark_api_key = "key-placeholder"
      end
      error = assert_raises(::RubyLLM::ConfigurationError) { ActiveAgent::Evals::RubyLLM.verify!(aardvark, context: context) }
      assert_equal "aardvark-1 runs on aardvark: #{error.cause.message.strip}", error.message
      assert_match(/Aardvark provider is not configured/, error.cause.message)
    end
  end

  # A provider that lists no requirements and refuses anyway leaves nothing
  # to name, so the refusal carries RubyLLM's own message. Registered last,
  # it also leads the sorted list an unknown provider's refusal gives.
  def test_verify_relays_ruby_llms_message_when_a_provider_lists_nothing_to_set
    with_provider(:aardvark) do
      aardvark = ModelSpec.new(label: "aardvark-1", provider: "aardvark", model: "aardvark-1")
      error = assert_raises(::RubyLLM::ConfigurationError) { ActiveAgent::Evals::RubyLLM.verify!(aardvark) }

      assert_equal "aardvark-1 runs on aardvark: #{error.cause.message.strip}", error.message
      assert_match(/Aardvark provider is not configured/, error.cause.message)

      acme = ModelSpec.new(label: "acme-1", provider: "acme", model: "acme-1")
      error = assert_raises(::RubyLLM::ConfigurationError) { ActiveAgent::Evals::RubyLLM.verify!(acme) }
      assert_includes error.message, "RubyLLM knows aardvark, "
    end
  end

  # Azure resolves a deployment name before it checks its keys: with the base
  # and key set, a deployment naming an unknown model is RubyLLM's refusal to
  # relay, not a key to set.
  def test_verify_relays_a_refusal_that_is_not_about_credentials
    skip "ruby_llm #{::RubyLLM::VERSION} has no azure_deployments" unless ::RubyLLM.config.respond_to?(:azure_deployments)

    context = ::RubyLLM.context do |config|
      config.azure_api_base = "https://support.example"
      config.azure_api_key = "key-placeholder"
      config.azure_deployments = { "support-deploy" => "no-such-model" }
    end
    deployment = ModelSpec.new(label: "support-deploy", provider: "azure", model: "support-deploy")

    error = assert_raises(::RubyLLM::ConfigurationError) { ActiveAgent::Evals::RubyLLM.verify!(deployment, context: context) }

    assert_equal "support-deploy runs on azure: #{error.cause.message.strip}", error.message
    assert_match(/unknown model "no-such-model"/, error.cause.message)
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
    assert_equal "boom", detail.call('{:ok=>false, :error=>"boom"}'), "error need not be the first key"
    assert_equal "denied", detail.call('{"error": true, "message": "denied"}')
    assert_nil detail.call('{"result": 1, "error": null}')
    assert_nil detail.call('{"error": false}')
    assert_nil detail.call('{"error": 0, "data": []}'), "a status code of zero is not a failure"
    assert_nil detail.call('{"content": [], "isError": false}')
    assert_nil detail.call("{:error=>nil}")
    assert_operator detail.call({ "error" => "x" * 50_000 }.to_json).bytesize, :<=,
      ActiveAgent::Evals::RubyLLM::DETAIL_LIMIT
  end

  # Only a whole inspected Hash with a top-level error counts: a tool that
  # returns source code, a log line or a nested error succeeded.
  def test_replay_does_not_read_errors_into_text_results
    detail = ->(content) { tool_result_detail(content) }

    assert_nil detail.call("the error log is empty")
    assert_nil detail.call('error: "something"'), "plain text"
    assert_nil detail.call('status: ok, error: "none"'), "a log line"
    assert_nil detail.call('res.status(404).json({ error: "Not found" })'), "source code"
    assert_nil detail.call({ items: [ { id: 1, error: "retry later" } ], ok: true }.to_s), "a nested error"
    assert_nil detail.call({ note: "{:error=>\"quoted\"}" }.to_s), "an error inside a string"
    assert_nil detail.call('{"items": [{"error": "retry later"}]}'), "a nested error in JSON"
  end

  def test_replay_keeps_error_details_valid_utf8
    inspected = "{:error=>\"caf\\xC3 x\"}"
    binary = "{\"status\": \"ok \xFF\"}".dup.force_encoding(Encoding::UTF_8)

    detail = tool_result_detail(inspected)
    assert detail.valid_encoding?, detail.inspect
    replay = ActiveAgent::Evals::RubyLLM.replay(tool_turn(binary))
    assert_equal "done", replay.answer, "a result with invalid bytes must not fail the replay"
    assert JSON.generate(replay.tool_calls)
  end

  # A provider can reuse a call id in a later turn; each result answers the
  # call that was still waiting for it.
  def test_replay_pairs_a_reused_call_id_with_the_call_it_answers
    call = ->(id) { { id => ToolCall.new(id: id, name: "lookup_order", arguments: {}) } }
    messages = [
      Message2.new(role: :user, content: "Where is it?"),
      Message2.new(role: :assistant, tool_calls: call.call("c1")),
      Message2.new(role: :tool, content: '{"error": "timed out"}', tool_call_id: "c1"),
      Message2.new(role: :assistant, tool_calls: call.call("c1")),
      Message2.new(role: :tool, content: '{"status": "shipped"}', tool_call_id: "c1"),
      Message2.new(role: :assistant, content: "Shipped.")
    ]

    replay = ActiveAgent::Evals::RubyLLM.replay(messages)

    assert_equal [ true, false ], replay.tool_calls.map { |tool_call| tool_call["error"] }
    assert_equal "timed out", replay.tool_calls.first["detail"]
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

  def test_replay_of_a_conversation_the_model_never_answered
    replay = ActiveAgent::Evals::RubyLLM.replay([ Message.new(role: "user", content: "Hi") ])

    assert_nil replay.answer
    assert_equal "The conversation ended on a user message without a reply", replay.error
    assert_equal 0, replay.total_tokens
    assert_equal [], replay.tool_calls
  end

  # The run failed after the new prompt was saved: the previous turn's reply
  # must not be scored as this one's answer.
  def test_an_earlier_turns_reply_is_not_the_answer
    messages = [
      Message.new(role: "user", content: "Hi"),
      Message.new(role: "assistant", content: "Hello!", input_tokens: 5, output_tokens: 2),
      Message.new(role: "user", content: "Where is order ABC-123?"),
      Message.new(role: "system", content: "Answer briefly.")
    ]

    replay = ActiveAgent::Evals::RubyLLM.replay(messages)

    assert_nil replay.answer
    assert_equal "The conversation ended on a user message without a reply", replay.error
  end

  private

  # The refusal for a provider whose key is unset: the names to set when the
  # installed ruby_llm lists the provider's requirements (each provider
  # verified this way lists its one key), RubyLLM's own message otherwise.
  def missing_key_message(label, provider, cause)
    provider_class = ::RubyLLM::Provider.providers.fetch(provider)
    names = provider_class.configuration_requirements.map { |name| name.to_s.upcase } if provider_class.respond_to?(:configuration_requirements)
    return "#{label} runs on #{provider}: #{cause.message.strip}" if names.nil? || names.empty?

    "#{label} runs on #{provider}, which has no API key. Set #{names.join(' and ')}."
  end

  # Registers a RubyLLM provider under `name` for the block, one RubyLLM
  # never finds configured, and removes it after. `requirements` are both
  # its configuration requirements and the options its configuration takes.
  def with_provider(name, requirements: [])
    skip "ruby_llm #{::RubyLLM::VERSION} registers no providers at runtime" unless ::RubyLLM::Provider.respond_to?(:register)

    provider_class = Class.new(::RubyLLM::Provider) do
      define_singleton_method(:configuration_requirements) { requirements }
      define_singleton_method(:configuration_options) { requirements }
      define_singleton_method(:configured?) { |_config| false }
      define_singleton_method(:display_name) { name.to_s.capitalize }
    end
    ::RubyLLM::Provider.register(name, provider_class)
    yield
  ensure
    ::RubyLLM::Provider.providers.delete(name)
  end

  # The cached-token keyword each RubyLLM generation's Message takes.
  def cached_tokens(count)
    Gem::Version.new(::RubyLLM::VERSION) >= Gem::Version.new("2") ? { cache_read_tokens: count } : { cached_tokens: count }
  end

  def tool_turn(content)
    [
      Message2.new(role: :assistant, tool_calls: { "c" => ToolCall.new(id: "c", name: "t", arguments: {}) }),
      Message2.new(role: :tool, content: content, tool_call_id: "c"),
      Message2.new(role: :assistant, content: "done")
    ]
  end

  def tool_result_detail(content)
    ActiveAgent::Evals::RubyLLM.replay(tool_turn(content)).tool_calls.first["detail"]
  end
end
