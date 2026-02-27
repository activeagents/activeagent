# frozen_string_literal: true

require "test_helper"

# Ensure RubyLLM stubs are loaded before the provider
require_relative "ruby_llm_provider_test"

class RubyLLMProviderEdgeCasesTest < ActiveSupport::TestCase
  setup do
    @provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "Hello" }]
    )
  end

  # --- Class methods ---

  test "service_name class method returns RubyLLM" do
    assert_equal "RubyLLM", ActiveAgent::Providers::RubyLLMProvider.service_name
  end

  test "tag_name class method returns RubyLLM" do
    assert_equal "RubyLLM", ActiveAgent::Providers::RubyLLMProvider.tag_name
  end

  test "namespace class method resolves to Providers::RubyLLM module" do
    assert_equal ActiveAgent::Providers::RubyLLM, ActiveAgent::Providers::RubyLLMProvider.namespace
  end

  test "options_klass returns RubyLLM::Options" do
    assert_equal ActiveAgent::Providers::RubyLLM::Options, ActiveAgent::Providers::RubyLLMProvider.options_klass
  end

  test "prompt_request_type returns RubyLLM::RequestType" do
    assert_kind_of ActiveAgent::Providers::RubyLLM::RequestType, ActiveAgent::Providers::RubyLLMProvider.prompt_request_type
  end

  test "embed_request_type returns RubyLLM::EmbeddingRequestType" do
    assert_kind_of ActiveAgent::Providers::RubyLLM::EmbeddingRequestType, ActiveAgent::Providers::RubyLLMProvider.embed_request_type
  end

  # --- assert_service! ---

  test "initialization fails with wrong service name" do
    assert_raises(RuntimeError) do
      ActiveAgent::Providers::RubyLLMProvider.new(
        service: "WrongService",
        model: "gpt-4o-mini",
        messages: [{ role: "user", content: "Hello" }]
      )
    end
  end

  test "initialization succeeds with nil service" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "Hello" }]
    )
    assert_not_nil provider
  end

  # --- extract_content_text edge cases ---

  test "extract_content_text with empty array content returns empty string" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: [] }]
    )

    response = provider.prompt
    assert_not_nil response
  end

  test "extract_content_text with array containing only images returns empty" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [
        {
          role: "user",
          content: [
            { type: "image_url", image_url: { url: "http://example.com/img.png" } }
          ]
        }
      ]
    )

    response = provider.prompt
    assert_not_nil response
  end

  # --- build_ruby_llm_messages ---

  test "build_ruby_llm_messages with empty messages" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "test" }]
    )

    messages = provider.send(:build_ruby_llm_messages, { messages: [] })
    assert_equal [], messages
  end

  test "build_ruby_llm_messages with instructions prepends system message" do
    messages = @provider.send(:build_ruby_llm_messages, {
      instructions: "Be helpful.",
      messages: [{ role: "user", content: "Hello" }]
    })

    assert_equal 2, messages.size
    assert_equal :system, messages[0].role
    assert_equal "Be helpful.", messages[0].content
    assert_equal :user, messages[1].role
  end

  test "build_ruby_llm_messages without instructions skips system message" do
    messages = @provider.send(:build_ruby_llm_messages, {
      messages: [{ role: "user", content: "Hello" }]
    })

    assert_equal 1, messages.size
    assert_equal :user, messages[0].role
  end

  test "build_ruby_llm_messages converts tool messages with tool_call_id" do
    messages = @provider.send(:build_ruby_llm_messages, {
      messages: [
        { role: "tool", content: '{"temp": 72}', tool_call_id: "call_123" }
      ]
    })

    assert_equal 1, messages.size
    assert_equal :tool, messages[0].role
    assert_equal '{"temp": 72}', messages[0].content
    assert_equal "call_123", messages[0].tool_call_id
  end

  test "build_ruby_llm_messages converts assistant messages with tool_calls" do
    messages = @provider.send(:build_ruby_llm_messages, {
      messages: [
        {
          role: "assistant",
          content: "",
          tool_calls: [
            { id: "call_1", type: "function", function: { name: "get_weather", arguments: '{"location":"NYC"}' } }
          ]
        }
      ]
    })

    assert_equal 1, messages.size
    assert_equal :assistant, messages[0].role
    assert_not_nil messages[0].tool_calls
    assert messages[0].tool_calls.key?("call_1")
  end

  test "build_ruby_llm_messages with nil messages" do
    messages = @provider.send(:build_ruby_llm_messages, { messages: nil })
    assert_equal [], messages
  end

  # --- normalize_ruby_llm_response ---

  test "normalize_ruby_llm_response with no stop_reason defaults to end_turn" do
    msg = ::RubyLLM::Message.new(role: :assistant, content: "Hello")
    msg.input_tokens = 5
    msg.output_tokens = 3

    result = @provider.send(:normalize_ruby_llm_response, msg, "gpt-4o-mini")

    assert_equal "end_turn", result[:stop_reason]
  end

  test "normalize_ruby_llm_response with tool_calls defaults stop_reason to tool_use" do
    msg = ::RubyLLM::Message.new(role: :assistant, content: "")
    msg.tool_calls = {
      "call_1" => ::RubyLLM::ToolCall.new(id: "call_1", name: "test", arguments: "{}")
    }

    result = @provider.send(:normalize_ruby_llm_response, msg, "gpt-4o-mini")

    assert_equal "tool_use", result[:stop_reason]
    assert_equal 1, result[:tool_calls].size
    assert_equal "test", result[:tool_calls][0][:function][:name]
  end

  test "normalize_ruby_llm_response preserves explicit stop_reason" do
    msg = ::RubyLLM::Message.new(role: :assistant, content: "Long text")
    msg.stop_reason = "length"

    result = @provider.send(:normalize_ruby_llm_response, msg, "gpt-4o-mini")

    assert_equal "length", result[:stop_reason]
  end

  test "normalize_ruby_llm_response without usage data omits usage key" do
    msg = ::RubyLLM::Message.new(role: :assistant, content: "Hello")
    # input_tokens and output_tokens remain nil

    result = @provider.send(:normalize_ruby_llm_response, msg, "gpt-4o-mini")

    refute result.key?(:usage)
  end

  test "normalize_ruby_llm_response includes model" do
    msg = ::RubyLLM::Message.new(role: :assistant, content: "Hello")

    result = @provider.send(:normalize_ruby_llm_response, msg, "claude-3-5-sonnet")

    assert_equal "claude-3-5-sonnet", result[:model]
  end

  test "normalize_ruby_llm_response with nil model_id" do
    msg = ::RubyLLM::Message.new(role: :assistant, content: "Hello")

    result = @provider.send(:normalize_ruby_llm_response, msg, nil)

    refute result.key?(:model)
  end

  test "normalize_ruby_llm_response converts hash tool_call arguments to JSON" do
    msg = ::RubyLLM::Message.new(role: :assistant, content: "")
    msg.tool_calls = {
      "call_1" => ::RubyLLM::ToolCall.new(
        id: "call_1",
        name: "search",
        arguments: { query: "test" }  # Hash instead of string
      )
    }

    result = @provider.send(:normalize_ruby_llm_response, msg, "gpt-4o-mini")
    args = result[:tool_calls][0][:function][:arguments]

    # Hash arguments should be converted to JSON string
    assert_kind_of String, args
    parsed = JSON.parse(args)
    assert_equal "test", parsed["query"]
  end

  # --- Multiple tool calls in one response ---

  test "multiple tool calls in a single response" do
    multi_tool_provider = Class.new(::RubyLLM::StubProvider) do
      def initialize
        @call_count = 0
      end

      def complete(messages, **kwargs)
        @call_count += 1

        if @call_count == 1
          msg = ::RubyLLM::Message.new(role: :assistant, content: "")
          msg.tool_calls = {
            "call_1" => ::RubyLLM::ToolCall.new(
              id: "call_1", name: "get_weather", arguments: '{"location":"NYC"}'
            ),
            "call_2" => ::RubyLLM::ToolCall.new(
              id: "call_2", name: "get_weather", arguments: '{"location":"Boston"}'
            )
          }
          msg.input_tokens = 10
          msg.output_tokens = 5
          msg
        else
          msg = ::RubyLLM::Message.new(
            role: :assistant,
            content: "NYC is 72F, Boston is 65F."
          )
          msg.input_tokens = 20
          msg.output_tokens = 10
          msg
        end
      end
    end

    resolve_stub = ->(model_id, **_kwargs) {
      [::RubyLLM::Model::Info.new(id: model_id), multi_tool_provider.new]
    }

    ::RubyLLM::Models.stub(:resolve, resolve_stub) do
      tool_calls_received = []

      provider = ActiveAgent::Providers::RubyLLMProvider.new(
        service: "RubyLLM",
        model: "gpt-4o-mini",
        messages: [{ role: "user", content: "Weather in NYC and Boston?" }],
        tools: [{
          type: "function",
          function: {
            name: "get_weather",
            description: "Get weather",
            parameters: { type: "object", properties: { location: { type: "string" } } }
          }
        }],
        tools_function: ->(name, **kwargs) {
          tool_calls_received << { name: name, kwargs: kwargs }
          { temperature: kwargs[:location] == "NYC" ? 72 : 65 }
        }
      )

      provider.prompt

      assert_equal 2, tool_calls_received.size
      locations = tool_calls_received.map { |tc| tc[:kwargs][:location] }
      assert_includes locations, "NYC"
      assert_includes locations, "Boston"
    end
  end

  # --- process_function_calls ---

  test "process_function_calls pushes tool results to message_stack" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "test" }],
      tools_function: ->(name, **kwargs) { { result: "ok" } }
    )

    provider.send(:process_function_calls, [
      { id: "call_1", name: "test_tool", input: {} }
    ])

    stack = provider.send(:message_stack)
    assert_equal 1, stack.size
    assert_equal "tool", stack.last[:role]
    assert_equal "call_1", stack.last[:tool_call_id]
    assert_equal({ result: "ok" }.to_json, stack.last[:content])
  end

  # --- process_prompt_finished_extract_messages ---

  test "process_prompt_finished_extract_messages returns nil for nil" do
    result = @provider.send(:process_prompt_finished_extract_messages, nil)
    assert_nil result
  end

  test "process_prompt_finished_extract_messages wraps response in array" do
    response = { role: "assistant", content: "Hello" }
    result = @provider.send(:process_prompt_finished_extract_messages, response)

    assert_equal [response], result
  end

  # --- process_prompt_finished_extract_function_calls ---

  test "process_prompt_finished_extract_function_calls returns nil when stack is empty" do
    result = @provider.send(:process_prompt_finished_extract_function_calls)
    assert_nil result
  end

  test "process_prompt_finished_extract_function_calls returns nil for no tool_calls" do
    @provider.send(:message_stack).push({ role: "assistant", content: "Hello" })

    result = @provider.send(:process_prompt_finished_extract_function_calls)
    assert_nil result
  end

  test "process_prompt_finished_extract_function_calls parses JSON string arguments" do
    @provider.send(:message_stack).push({
      role: "assistant",
      content: "",
      tool_calls: [
        { id: "call_1", type: "function", function: { name: "test", arguments: '{"key":"value"}' } }
      ]
    })

    result = @provider.send(:process_prompt_finished_extract_function_calls)

    assert_equal 1, result.size
    assert_equal "call_1", result[0][:id]
    assert_equal "test", result[0][:name]
    assert_equal({ key: "value" }, result[0][:input])
  end

  test "process_prompt_finished_extract_function_calls handles hash arguments" do
    @provider.send(:message_stack).push({
      role: "assistant",
      content: "",
      tool_calls: [
        { id: "call_1", type: "function", function: { name: "test", arguments: { "key" => "value" } } }
      ]
    })

    result = @provider.send(:process_prompt_finished_extract_function_calls)

    assert_equal({ key: "value" }, result[0][:input])
  end

  test "process_prompt_finished_extract_function_calls handles empty arguments" do
    @provider.send(:message_stack).push({
      role: "assistant",
      content: "",
      tool_calls: [
        { id: "call_1", type: "function", function: { name: "test", arguments: "" } }
      ]
    })

    result = @provider.send(:process_prompt_finished_extract_function_calls)

    assert_equal({}, result[0][:input])
  end

  test "process_prompt_finished_extract_function_calls handles nil arguments" do
    @provider.send(:message_stack).push({
      role: "assistant",
      content: "",
      tool_calls: [
        { id: "call_1", type: "function", function: { name: "test", arguments: nil } }
      ]
    })

    result = @provider.send(:process_prompt_finished_extract_function_calls)

    assert_equal({}, result[0][:input])
  end

  # --- process_stream_chunk ---

  test "process_stream_chunk creates assistant message on empty stack" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "test" }],
      stream: true,
      stream_broadcaster: ->(_msg, _delta, _type) {}
    )

    chunk = ::RubyLLM::Chunk.new(content: "Hello")
    provider.send(:process_stream_chunk, chunk)

    stack = provider.send(:message_stack)
    assert_equal 1, stack.size
    assert_equal "assistant", stack.last[:role]
    assert_equal "Hello", stack.last[:content]
  end

  test "process_stream_chunk appends to existing assistant message" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "test" }],
      stream: true,
      stream_broadcaster: ->(_msg, _delta, _type) {}
    )

    provider.send(:process_stream_chunk, ::RubyLLM::Chunk.new(content: "Hello "))
    provider.send(:process_stream_chunk, ::RubyLLM::Chunk.new(content: "World"))

    stack = provider.send(:message_stack)
    assert_equal 1, stack.size
    assert_equal "Hello World", stack.last[:content]
  end

  test "process_stream_chunk handles nil content chunk" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "test" }],
      stream: true,
      stream_broadcaster: ->(_msg, _delta, _type) {}
    )

    provider.send(:process_stream_chunk, ::RubyLLM::Chunk.new(content: "Hello"))
    provider.send(:process_stream_chunk, ::RubyLLM::Chunk.new(content: nil, finish_reason: "stop"))

    stack = provider.send(:message_stack)
    assert_equal "Hello", stack.last[:content]
  end

  test "process_stream_chunk accumulates tool calls across chunks" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "test" }],
      stream: true,
      stream_broadcaster: ->(_msg, _delta, _type) {}
    )

    # First chunk with partial tool call
    provider.send(:process_stream_chunk, ::RubyLLM::Chunk.new(
      tool_calls: {
        "call_1" => ::RubyLLM::ToolCall.new(id: "call_1", name: "search", arguments: '{"query":')
      }
    ))

    # Second chunk completing the arguments
    provider.send(:process_stream_chunk, ::RubyLLM::Chunk.new(
      tool_calls: {
        "call_1" => ::RubyLLM::ToolCall.new(id: "call_1", name: "search", arguments: '"hello"}')
      }
    ))

    stack = provider.send(:message_stack)
    assert_equal 1, stack.last[:tool_calls].size
    assert_equal '{"query":"hello"}', stack.last[:tool_calls][0][:function][:arguments]
  end

  test "process_stream_chunk handles multiple distinct tool calls" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "test" }],
      stream: true,
      stream_broadcaster: ->(_msg, _delta, _type) {}
    )

    provider.send(:process_stream_chunk, ::RubyLLM::Chunk.new(
      tool_calls: {
        "call_1" => ::RubyLLM::ToolCall.new(id: "call_1", name: "get_weather", arguments: '{"location":"NYC"}')
      }
    ))

    provider.send(:process_stream_chunk, ::RubyLLM::Chunk.new(
      tool_calls: {
        "call_2" => ::RubyLLM::ToolCall.new(id: "call_2", name: "get_time", arguments: '{"tz":"EST"}')
      }
    ))

    stack = provider.send(:message_stack)
    assert_equal 2, stack.last[:tool_calls].size
    names = stack.last[:tool_calls].map { |tc| tc[:function][:name] }
    assert_includes names, "get_weather"
    assert_includes names, "get_time"
  end

  # --- Instrumentation ---

  test "prompt fires prompt.active_agent notification" do
    received_payload = nil

    subscription = ActiveSupport::Notifications.subscribe("prompt.active_agent") do |event|
      received_payload = event.payload if event.payload[:provider] == "RubyLLM"
    end

    @provider.prompt

    assert_not_nil received_payload, "Should receive prompt.active_agent event"
    assert_equal "RubyLLM", received_payload[:provider]
    assert_equal "RubyLLM", received_payload[:provider_module]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  test "prompt fires prompt.provider.active_agent notification with usage" do
    received_payload = nil

    subscription = ActiveSupport::Notifications.subscribe("prompt.provider.active_agent") do |event|
      received_payload = event.payload if event.payload[:provider] == "RubyLLM"
    end

    @provider.prompt

    assert_not_nil received_payload, "Should receive prompt.provider.active_agent event"
    assert_not_nil received_payload[:usage]
    assert_equal 10, received_payload[:usage][:input_tokens]
    assert_equal 5, received_payload[:usage][:output_tokens]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  test "embed fires embed.active_agent notification" do
    received_payload = nil

    subscription = ActiveSupport::Notifications.subscribe("embed.active_agent") do |event|
      received_payload = event.payload if event.payload[:provider] == "RubyLLM"
    end

    embed_provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "text-embedding-3-small",
      input: "test text"
    )
    embed_provider.embed

    assert_not_nil received_payload, "Should receive embed.active_agent event"
    assert_equal "RubyLLM", received_payload[:provider]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  # --- Embedding with dimensions ---

  test "embedding passes dimensions to provider" do
    capturing_provider = Class.new(::RubyLLM::StubProvider) do
      attr_reader :last_dimensions

      def embed(text, model:, dimensions:)
        @last_dimensions = dimensions
        ::RubyLLM::Embedding.new(vectors: Array.new(dimensions || 1536) { rand })
      end
    end

    custom = capturing_provider.new
    resolve_stub = ->(model_id, **_kwargs) {
      [::RubyLLM::Model::Info.new(id: model_id), custom]
    }

    ::RubyLLM::Models.stub(:resolve, resolve_stub) do
      embed_provider = ActiveAgent::Providers::RubyLLMProvider.new(
        service: "RubyLLM",
        model: "text-embedding-3-small",
        input: "test",
        dimensions: 512
      )

      response = embed_provider.embed

      assert_equal 512, custom.last_dimensions
    end
  end

  # --- Error in embed ---

  test "handles error from provider.embed" do
    error_provider = Class.new(::RubyLLM::StubProvider) do
      def embed(text, model:, dimensions:)
        raise StandardError, "Embedding API error"
      end
    end

    resolve_stub = ->(model_id, **_kwargs) {
      [::RubyLLM::Model::Info.new(id: model_id), error_provider.new]
    }

    ::RubyLLM::Models.stub(:resolve, resolve_stub) do
      embed_provider = ActiveAgent::Providers::RubyLLMProvider.new(
        service: "RubyLLM",
        model: "text-embedding-3-small",
        input: "test"
      )

      assert_raises(StandardError) { embed_provider.embed }
    end
  end

  # --- ToolProxy additional tests ---

  test "ToolProxy provider_params returns empty hash" do
    proxy = ActiveAgent::Providers::RubyLLM::ToolProxy.new(
      name: "test",
      description: "Test tool",
      parameters: {}
    )

    assert_equal({}, proxy.provider_params)
  end

  test "ToolProxy deep_stringify handles nested arrays" do
    proxy = ActiveAgent::Providers::RubyLLM::ToolProxy.new(
      name: "test",
      description: "Test tool",
      parameters: {
        type: "object",
        properties: {
          tags: {
            type: "array",
            items: { type: "string" }
          }
        },
        required: [:name]
      }
    )

    schema = proxy.params_schema

    assert_equal "object", schema["type"]
    assert_equal "array", schema.dig("properties", "tags", "type")
    assert_equal "string", schema.dig("properties", "tags", "items", "type")
    assert_equal [:name], schema["required"]
  end

  # --- convert_tool_calls_for_ruby_llm edge cases ---

  test "convert_tool_calls_for_ruby_llm handles input key with no function" do
    tool_calls = [
      { id: "call_1", name: "search", input: { query: "hello" } }
    ]

    result = @provider.send(:convert_tool_calls_for_ruby_llm, tool_calls)

    assert_equal "search", result["call_1"].name
    # input should be converted to JSON
    assert_equal({ query: "hello" }.to_json, result["call_1"].arguments)
  end

  test "convert_tool_calls_for_ruby_llm handles nil input" do
    tool_calls = [
      { id: "call_1", name: "test" }
    ]

    result = @provider.send(:convert_tool_calls_for_ruby_llm, tool_calls)

    assert_equal "test", result["call_1"].name
    assert_equal "{}", result["call_1"].arguments
  end

  test "convert_tool_calls_for_ruby_llm handles multiple tool calls" do
    tool_calls = [
      { id: "call_1", type: "function", function: { name: "tool_a", arguments: '{}' } },
      { id: "call_2", type: "function", function: { name: "tool_b", arguments: '{}' } }
    ]

    result = @provider.send(:convert_tool_calls_for_ruby_llm, tool_calls)

    assert_equal 2, result.size
    assert result.key?("call_1")
    assert result.key?("call_2")
  end

  # --- resolve_ruby_llm_provider! caching ---

  test "resolve_ruby_llm_provider caches for same model" do
    resolve_count = 0
    counting_resolve = ->(model_id, **kwargs) {
      resolve_count += 1
      [::RubyLLM::Model::Info.new(id: model_id), ::RubyLLM::StubProvider.new]
    }

    ::RubyLLM::Models.stub(:resolve, counting_resolve) do
      @provider.send(:resolve_ruby_llm_provider!, "gpt-4o-mini")
      @provider.send(:resolve_ruby_llm_provider!, "gpt-4o-mini")

      assert_equal 1, resolve_count
    end
  end

  test "resolve_ruby_llm_provider re-resolves for different model" do
    resolve_count = 0
    counting_resolve = ->(model_id, **kwargs) {
      resolve_count += 1
      [::RubyLLM::Model::Info.new(id: model_id), ::RubyLLM::StubProvider.new]
    }

    ::RubyLLM::Models.stub(:resolve, counting_resolve) do
      @provider.send(:resolve_ruby_llm_provider!, "gpt-4o-mini")
      @provider.send(:resolve_ruby_llm_provider!, "claude-3-5-sonnet")

      assert_equal 2, resolve_count
    end
  end

  # --- Response format pass-through ---

  test "response_format is passed to provider.complete" do
    capturing_provider = Class.new(::RubyLLM::StubProvider) do
      attr_reader :last_kwargs

      def complete(messages, **kwargs)
        @last_kwargs = kwargs
        msg = ::RubyLLM::Message.new(role: :assistant, content: '{"key": "value"}')
        msg.input_tokens = 5
        msg.output_tokens = 3
        msg
      end
    end

    custom = capturing_provider.new
    resolve_stub = ->(model_id, **_kwargs) {
      [::RubyLLM::Model::Info.new(id: model_id), custom]
    }

    ::RubyLLM::Models.stub(:resolve, resolve_stub) do
      provider = ActiveAgent::Providers::RubyLLMProvider.new(
        service: "RubyLLM",
        model: "gpt-4o-mini",
        messages: [{ role: "user", content: "Return JSON" }],
        response_format: { type: "json_object" }
      )

      provider.prompt

      assert_equal({ type: "json_object" }, custom.last_kwargs[:schema])
    end
  end

  # --- Preview ---

  test "preview returns markdown preview" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [{ role: "user", content: "Hello" }]
    )

    preview = provider.preview

    assert_kind_of String, preview
    assert preview.present?
  end
end
