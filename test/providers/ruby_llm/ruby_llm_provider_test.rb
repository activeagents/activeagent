# frozen_string_literal: true

require "test_helper"

# Stub RubyLLM gem classes for testing without the gem installed.
# These stubs match the real RubyLLM API surface used by the provider.
#
# When the real ruby_llm gem is already loaded (e.g. integration tests ran
# first), we skip defining stubs and fall through to StubProvider only.
unless defined?(::RubyLLM::Models)
  module ::RubyLLM
    def self.config
      @config ||= Struct.new(:openai_api_key).new("test")
    end

    class Message
      attr_accessor :role, :content, :tool_calls, :tool_call_id,
                    :input_tokens, :output_tokens, :stop_reason

      def initialize(role:, content: nil, tool_calls: nil, tool_call_id: nil, **_kwargs)
        @role = role
        @content = content
        @tool_calls = tool_calls
        @tool_call_id = tool_call_id
        @input_tokens = nil
        @output_tokens = nil
        @stop_reason = nil
      end

      def tool_call?
        tool_calls&.any?
      end
    end

    class ToolCall
      attr_accessor :id, :name, :arguments

      def initialize(id:, name:, arguments: "{}")
        @id = id
        @name = name
        @arguments = arguments
      end
    end

    class Chunk
      attr_accessor :content, :tool_calls, :finish_reason

      def initialize(content: nil, tool_calls: nil, finish_reason: nil)
        @content = content
        @tool_calls = tool_calls
        @finish_reason = finish_reason
      end
    end

    module Model
      class Info
        attr_reader :id, :provider
        def initialize(data)
          data = { id: data } if data.is_a?(String)
          @id = data[:id]
          @provider = data[:provider] || "openai"
        end
      end
    end

    class Embedding
      attr_accessor :vectors

      def initialize(vectors:)
        @vectors = vectors
      end
    end

    # Use a module so it doesn't conflict with the real gem's class Models
    module Models
      @default_provider = nil

      def self.resolve(model_id, **_kwargs)
        [ Model::Info.new(id: model_id, provider: "openai"), @default_provider ]
      end

      def self.default_provider
        @default_provider
      end

      def self.default_provider=(provider)
        @default_provider = provider
      end
    end
  end
end

# StubProvider lives outside the guard so it's always available for tests,
# whether the real gem is loaded or not.
module ::RubyLLM
  class StubProvider
    attr_reader :last_messages, :last_kwargs

    def complete(messages, tools:, temperature:, model:, **kwargs, &block)
      @last_messages = messages
      @last_kwargs = { tools: tools, temperature: temperature, model: model }.merge(kwargs)

      if block_given?
        block.call(Chunk.new(content: "Hello "))
        block.call(Chunk.new(content: "world"))
        block.call(Chunk.new(content: nil, finish_reason: "stop"))
        nil
      else
        msg = Message.new(role: :assistant, content: "Hello from RubyLLM")
        msg.input_tokens = 10
        msg.output_tokens = 5
        msg
      end
    end

    def embed(text, model:, dimensions:)
      Embedding.new(vectors: Array.new(1536) { rand * 2 - 1 })
    end
  end

  # Set default provider for stub Models (no-op if real gem is loaded)
  if defined?(::RubyLLM::Models) && ::RubyLLM::Models.respond_to?(:default_provider=)
    ::RubyLLM::Models.default_provider = StubProvider.new
  end
end

# RubyLLM stubs are defined above, so require_gem! will be skipped
# via the `unless defined?(::RubyLLM)` guard in the provider file.
require "active_agent/providers/ruby_llm_provider"

class RubyLLMProviderTest < ActiveSupport::TestCase
  setup do
    @provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [
        { role: "user", content: "Hello world" }
      ]
    )
  end

  # --- Basic provider setup ---

  test "service_name returns RubyLLM" do
    assert_equal "RubyLLM", @provider.service_name
  end

  test "provider initializes with valid config" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "claude-3-5-haiku",
      temperature: 0.7,
      messages: [
        { role: "user", content: "Hello" }
      ]
    )

    assert_not_nil provider
    assert_equal "RubyLLM", provider.service_name
  end

  test "provider initializes with max_tokens option" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      max_tokens: 1024,
      messages: [ { role: "user", content: "Hello" } ]
    )

    assert_not_nil provider
  end

  # --- Non-streaming prompts ---

  test "non-streaming prompt returns proper response structure" do
    response = @provider.prompt

    assert_not_nil response
    assert_not_nil response.raw_request
    assert_not_nil response.raw_response
    assert response.messages.size >= 1

    message = response.messages.last
    assert_equal "assistant", message.role
    assert_equal "Hello from RubyLLM", message.content
  end

  test "prompt includes usage data" do
    response = @provider.prompt

    assert_not_nil response.usage
    assert_equal 10, response.usage.input_tokens
    assert_equal 5, response.usage.output_tokens
  end

  test "prompt includes stop_reason in raw_response" do
    response = @provider.prompt

    assert_equal "end_turn", response.raw_response[:stop_reason]
  end

  test "prompt includes model in raw_response" do
    response = @provider.prompt

    assert_equal "gpt-4o-mini", response.raw_response[:model]
  end

  # --- Streaming ---

  test "streaming broadcasts open, update, and close events" do
    stream_events = []

    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [ { role: "user", content: "hello" } ],
      stream: true,
      stream_broadcaster: ->(message, delta, event_type) {
        stream_events << { message: message, delta: delta, type: event_type }
      }
    )

    provider.prompt

    assert stream_events.any? { |e| e[:type] == :open }
    assert stream_events.any? { |e| e[:type] == :update }
    assert stream_events.any? { |e| e[:type] == :close }
  end

  test "streaming accumulates content from chunks" do
    stream_events = []

    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [ { role: "user", content: "hello" } ],
      stream: true,
      stream_broadcaster: ->(message, delta, event_type) {
        stream_events << { message: message&.dup, delta: delta, type: event_type }
      }
    )

    provider.prompt

    updates = stream_events.select { |e| e[:type] == :update }
    assert_equal "Hello ", updates.first[:delta]
    assert_equal "world", updates.last[:delta]
  end

  test "streaming with tool calls accumulates tool_calls" do
    streaming_tool_provider = Class.new(::RubyLLM::StubProvider) do
      def initialize
        @call_count = 0
      end

      def complete(messages, **kwargs, &block)
        @call_count += 1

        if block_given? && @call_count == 1
          # Stream a tool call across chunks
          block.call(::RubyLLM::Chunk.new(
            tool_calls: {
              "call_1" => ::RubyLLM::ToolCall.new(
                id: "call_1",
                name: "get_weather",
                arguments: '{"location":'
              )
            }
          ))
          block.call(::RubyLLM::Chunk.new(
            tool_calls: {
              "call_1" => ::RubyLLM::ToolCall.new(
                id: "call_1",
                name: "get_weather",
                arguments: '"Boston"}'
              )
            }
          ))
          block.call(::RubyLLM::Chunk.new(finish_reason: "tool_calls"))
          nil
        elsif block_given?
          # Second streaming call after tool results - return text
          block.call(::RubyLLM::Chunk.new(content: "It's 72F in Boston."))
          block.call(::RubyLLM::Chunk.new(finish_reason: "stop"))
          nil
        else
          msg = ::RubyLLM::Message.new(role: :assistant, content: "It's 72F in Boston.")
          msg.input_tokens = 10
          msg.output_tokens = 5
          msg
        end
      end
    end

    with_custom_provider(streaming_tool_provider.new) do
      stream_events = []

      provider = ActiveAgent::Providers::RubyLLMProvider.new(
        service: "RubyLLM",
        model: "gpt-4o-mini",
        messages: [ { role: "user", content: "weather?" } ],
        stream: true,
        tools: [ tool_definition("get_weather") ],
        tools_function: ->(_name, **_kwargs) { { temp: 72 } },
        stream_broadcaster: ->(message, delta, event_type) {
          stream_events << { message: message&.deep_dup, type: event_type }
        }
      )

      provider.prompt

      # Check that the streamed message accumulated the tool call arguments
      assert stream_events.any? { |e| e[:type] == :open }
      assert stream_events.any? { |e| e[:type] == :close }
    end
  end

  # --- Embeddings ---

  test "embedding returns proper response structure" do
    embed_provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      input: "test text",
      model: "text-embedding-3-small"
    )

    response = embed_provider.embed

    assert_not_nil response
    assert_not_nil response.data
    assert_equal 1, response.data.size

    embedding = response.data.first
    assert_equal "embedding", embedding[:object]
    assert_equal 1536, embedding[:embedding].size
  end

  test "multiple embeddings return proper structure" do
    embed_provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      input: [ "first text", "second text" ],
      model: "text-embedding-3-small"
    )

    response = embed_provider.embed

    assert_equal 2, response.data.size
    assert_equal 0, response.data[0][:index]
    assert_equal 1, response.data[1][:index]
  end

  # --- Tool calling ---

  test "tool call extraction works correctly with multi-turn" do
    tool_call_provider = Class.new(::RubyLLM::StubProvider) do
      def initialize
        @call_count = 0
      end

      def complete(messages, **kwargs)
        @call_count += 1

        if @call_count == 1
          msg = ::RubyLLM::Message.new(role: :assistant, content: "")
          msg.tool_calls = {
            "call_123" => ::RubyLLM::ToolCall.new(
              id: "call_123",
              name: "get_weather",
              arguments: '{"location":"Boston"}'
            )
          }
          msg.input_tokens = 10
          msg.output_tokens = 5
          msg
        else
          msg = ::RubyLLM::Message.new(role: :assistant, content: "The weather in Boston is sunny and 72F.")
          msg.input_tokens = 20
          msg.output_tokens = 10
          msg
        end
      end
    end

    with_custom_provider(tool_call_provider.new) do
      tool_calls_received = []

      provider = ActiveAgent::Providers::RubyLLMProvider.new(
        service: "RubyLLM",
        model: "gpt-4o-mini",
        messages: [ { role: "user", content: "What is the weather in Boston?" } ],
        tools: [ tool_definition("get_weather") ],
        tools_function: ->(name, **kwargs) {
          tool_calls_received << { name: name, kwargs: kwargs }
          { temperature: 72, condition: "sunny" }
        }
      )

      provider.prompt

      assert_equal 1, tool_calls_received.size
      assert_equal "get_weather", tool_calls_received.first[:name]
      assert_equal({ location: "Boston" }, tool_calls_received.first[:kwargs])
    end
  end

  test "tool call response sets stop_reason to tool_use" do
    tool_call_provider = Class.new(::RubyLLM::StubProvider) do
      def initialize
        @call_count = 0
      end

      def complete(messages, **kwargs)
        @call_count += 1

        if @call_count == 1
          msg = ::RubyLLM::Message.new(role: :assistant, content: "")
          msg.tool_calls = {
            "call_1" => ::RubyLLM::ToolCall.new(id: "call_1", name: "test_tool", arguments: "{}")
          }
          msg.input_tokens = 5
          msg.output_tokens = 3
          msg
        else
          msg = ::RubyLLM::Message.new(role: :assistant, content: "Done.")
          msg.input_tokens = 10
          msg.output_tokens = 5
          msg
        end
      end
    end

    with_custom_provider(tool_call_provider.new) do
      provider = ActiveAgent::Providers::RubyLLMProvider.new(
        service: "RubyLLM",
        model: "gpt-4o-mini",
        messages: [ { role: "user", content: "do it" } ],
        tools: [ tool_definition("test_tool") ],
        tools_function: ->(_name, **_kwargs) { "ok" }
      )

      response = provider.prompt
      # Final response should be end_turn since it's the completion
      assert_equal "end_turn", response.raw_response[:stop_reason]
    end
  end

  test "tool call with hash arguments works" do
    tool_call_provider = Class.new(::RubyLLM::StubProvider) do
      def initialize
        @call_count = 0
      end

      def complete(messages, **kwargs)
        @call_count += 1

        if @call_count == 1
          msg = ::RubyLLM::Message.new(role: :assistant, content: "")
          msg.tool_calls = {
            "call_1" => ::RubyLLM::ToolCall.new(
              id: "call_1",
              name: "search",
              arguments: { query: "test" }  # Hash instead of string
            )
          }
          msg.input_tokens = 5
          msg.output_tokens = 3
          msg
        else
          msg = ::RubyLLM::Message.new(role: :assistant, content: "Found it.")
          msg.input_tokens = 10
          msg.output_tokens = 5
          msg
        end
      end
    end

    with_custom_provider(tool_call_provider.new) do
      tool_calls_received = []

      provider = ActiveAgent::Providers::RubyLLMProvider.new(
        service: "RubyLLM",
        model: "gpt-4o-mini",
        messages: [ { role: "user", content: "search" } ],
        tools: [ tool_definition("search") ],
        tools_function: ->(name, **kwargs) {
          tool_calls_received << { name: name, kwargs: kwargs }
          "result"
        }
      )

      provider.prompt

      assert_equal 1, tool_calls_received.size
      assert_equal "search", tool_calls_received.first[:name]
    end
  end

  # --- ToolChoiceClearing ---

  test "tool_choice_forces_required? returns true for required" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      tool_choice: "required",
      messages: [ { role: "user", content: "test" } ],
      tools: [ tool_definition("test_tool") ],
      tools_function: ->(_name, **_kwargs) { "ok" }
    )

    # Initialize request so tool_choice is accessible
    provider.send(:request=, provider.send(:prompt_request_type).cast(
      tool_choice: "required", model: "gpt-4o-mini",
      messages: [ { role: "user", content: "test" } ]
    ))

    assert provider.send(:tool_choice_forces_required?)
  end

  test "tool_choice_forces_required? returns false for auto" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      tool_choice: "auto",
      messages: [ { role: "user", content: "test" } ],
      tools: [ tool_definition("test_tool") ],
      tools_function: ->(_name, **_kwargs) { "ok" }
    )

    provider.send(:request=, provider.send(:prompt_request_type).cast(
      tool_choice: "auto", model: "gpt-4o-mini",
      messages: [ { role: "user", content: "test" } ]
    ))

    refute provider.send(:tool_choice_forces_required?)
  end

  test "tool_choice_forces_specific? returns tool name for hash" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      tool_choice: { name: "get_weather" },
      messages: [ { role: "user", content: "test" } ],
      tools: [ tool_definition("get_weather") ],
      tools_function: ->(_name, **_kwargs) { "ok" }
    )

    provider.send(:request=, provider.send(:prompt_request_type).cast(
      tool_choice: { name: "get_weather" }, model: "gpt-4o-mini",
      messages: [ { role: "user", content: "test" } ]
    ))

    forces, name = provider.send(:tool_choice_forces_specific?)
    assert forces
    assert_equal "get_weather", name
  end

  test "tool_choice_forces_specific? returns false for string" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      tool_choice: "auto",
      messages: [ { role: "user", content: "test" } ],
      tools: [ tool_definition("test_tool") ],
      tools_function: ->(_name, **_kwargs) { "ok" }
    )

    provider.send(:request=, provider.send(:prompt_request_type).cast(
      tool_choice: "auto", model: "gpt-4o-mini",
      messages: [ { role: "user", content: "test" } ]
    ))

    forces, name = provider.send(:tool_choice_forces_specific?)
    refute forces
    assert_nil name
  end

  test "extract_used_function_names returns names from message_stack" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [ { role: "user", content: "test" } ]
    )

    # Simulate message_stack with assistant tool calls
    provider.send(:message_stack).push(
      {
        role: "assistant",
        content: "",
        tool_calls: [
          { id: "call_1", type: "function", function: { name: "get_weather", arguments: "{}" } },
          { id: "call_2", type: "function", function: { name: "get_time", arguments: "{}" } }
        ]
      }
    )

    names = provider.send(:extract_used_function_names)
    assert_includes names, "get_weather"
    assert_includes names, "get_time"
    assert_equal 2, names.size
  end

  test "extract_used_function_names returns empty array when no tool calls" do
    names = @provider.send(:extract_used_function_names)
    assert_equal [], names
  end

  test "prepare_prompt_request clears tool_choice after forced tool is used" do
    tool_call_provider = Class.new(::RubyLLM::StubProvider) do
      def initialize
        @call_count = 0
      end

      def complete(messages, **kwargs)
        @call_count += 1

        if @call_count == 1
          msg = ::RubyLLM::Message.new(role: :assistant, content: "")
          msg.tool_calls = {
            "call_1" => ::RubyLLM::ToolCall.new(id: "call_1", name: "get_weather", arguments: '{"location":"NYC"}')
          }
          msg.input_tokens = 5
          msg.output_tokens = 3
          msg
        else
          msg = ::RubyLLM::Message.new(role: :assistant, content: "72F in NYC.")
          msg.input_tokens = 10
          msg.output_tokens = 5
          msg
        end
      end
    end

    with_custom_provider(tool_call_provider.new) do
      provider = ActiveAgent::Providers::RubyLLMProvider.new(
        service: "RubyLLM",
        model: "gpt-4o-mini",
        tool_choice: "required",
        messages: [ { role: "user", content: "weather?" } ],
        tools: [ tool_definition("get_weather") ],
        tools_function: ->(_name, **_kwargs) { { temp: 72 } }
      )

      provider.prompt

      # After the tool was used and the second turn ran, tool_choice
      # should have been cleared by prepare_prompt_request_tools
      assert_nil provider.send(:request).tool_choice
    end
  end

  # --- System messages ---

  test "handles system instructions" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      instructions: "You are a helpful assistant.",
      messages: [
        { role: "user", content: "Hello" }
      ]
    )

    response = provider.prompt

    assert_not_nil response
    assert_equal "Hello from RubyLLM", response.messages.last.content
  end

  test "system role messages in messages array are handled" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [
        { role: "system", content: "You are helpful." },
        { role: "user", content: "Hello" }
      ]
    )

    response = provider.prompt

    assert_not_nil response
    # Should have system + user + assistant messages
    assert response.messages.size >= 2
  end

  # --- Multi-turn conversation ---

  test "multi-turn conversation with existing history" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [
        { role: "user", content: "What is 2+2?" },
        { role: "assistant", content: "4" },
        { role: "user", content: "And 3+3?" }
      ]
    )

    response = provider.prompt

    assert_not_nil response
    # Should include all conversation history plus new assistant response
    assert response.messages.size >= 3
  end

  test "conversation with tool_calls in history" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [
        { role: "user", content: "Get weather" },
        {
          role: "assistant", content: "",
          tool_calls: [
            { id: "call_1", type: "function", function: { name: "get_weather", arguments: '{"location":"NYC"}' } }
          ]
        },
        { role: "tool", content: '{"temp":72}', tool_call_id: "call_1" },
        { role: "assistant", content: "It's 72F in NYC." },
        { role: "user", content: "What about Boston?" }
      ]
    )

    response = provider.prompt

    assert_not_nil response
    assert response.messages.size >= 5
  end

  # --- Array content format ---

  test "array content with text blocks is extracted" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [
        {
          role: "user",
          content: [
            { type: "text", text: "Hello" },
            { type: "text", text: "World" }
          ]
        }
      ]
    )

    response = provider.prompt

    assert_not_nil response
  end

  test "array content filters non-text blocks" do
    provider = ActiveAgent::Providers::RubyLLMProvider.new(
      service: "RubyLLM",
      model: "gpt-4o-mini",
      messages: [
        {
          role: "user",
          content: [
            { type: "image_url", image_url: { url: "data:image/png;base64,..." } },
            { type: "text", text: "Describe this image" }
          ]
        }
      ]
    )

    response = provider.prompt

    assert_not_nil response
  end

  # --- Empty/nil tool_calls ---

  test "empty tool_calls in response does not break extraction" do
    empty_tool_provider = Class.new(::RubyLLM::StubProvider) do
      def complete(messages, **kwargs)
        msg = ::RubyLLM::Message.new(role: :assistant, content: "No tools needed.")
        msg.tool_calls = {}
        msg.input_tokens = 5
        msg.output_tokens = 3
        msg
      end
    end

    with_custom_provider(empty_tool_provider.new) do
      provider = ActiveAgent::Providers::RubyLLMProvider.new(
        service: "RubyLLM",
        model: "gpt-4o-mini",
        messages: [ { role: "user", content: "hello" } ]
      )

      response = provider.prompt

      assert_not_nil response
      assert_equal "No tools needed.", response.messages.last.content
    end
  end

  test "nil tool_calls in response does not break extraction" do
    nil_tool_provider = Class.new(::RubyLLM::StubProvider) do
      def complete(messages, **kwargs)
        msg = ::RubyLLM::Message.new(role: :assistant, content: "Just text.")
        msg.tool_calls = nil
        msg.input_tokens = 5
        msg.output_tokens = 3
        msg
      end
    end

    with_custom_provider(nil_tool_provider.new) do
      provider = ActiveAgent::Providers::RubyLLMProvider.new(
        service: "RubyLLM",
        model: "gpt-4o-mini",
        messages: [ { role: "user", content: "hello" } ]
      )

      response = provider.prompt

      assert_not_nil response
      assert_equal "Just text.", response.messages.last.content
    end
  end

  # --- Provider caching ---

  test "provider is cached across multi-turn calls" do
    resolve_call_count = 0

    tool_call_provider = Class.new(::RubyLLM::StubProvider) do
      def initialize
        @call_count = 0
      end

      def complete(messages, **kwargs)
        @call_count += 1

        if @call_count == 1
          msg = ::RubyLLM::Message.new(role: :assistant, content: "")
          msg.tool_calls = {
            "call_1" => ::RubyLLM::ToolCall.new(id: "call_1", name: "test", arguments: "{}")
          }
          msg.input_tokens = 5
          msg.output_tokens = 3
          msg
        else
          msg = ::RubyLLM::Message.new(role: :assistant, content: "Done.")
          msg.input_tokens = 5
          msg.output_tokens = 3
          msg
        end
      end
    end

    custom = tool_call_provider.new
    counting_resolve = ->(model_id, **kwargs) {
      resolve_call_count += 1
      [ stub_model_info(model_id), custom ]
    }

    ::RubyLLM::Models.stub(:resolve, counting_resolve) do
      provider = ActiveAgent::Providers::RubyLLMProvider.new(
        service: "RubyLLM",
        model: "gpt-4o-mini",
        messages: [ { role: "user", content: "test" } ],
        tools: [ tool_definition("test") ],
        tools_function: ->(_name, **_kwargs) { "ok" }
      )

      provider.prompt

      # Models.resolve should only be called once despite multi-turn
      assert_equal 1, resolve_call_count
    end
  end

  # --- stop_reason from RubyLLM response ---

  test "stop_reason from RubyLLM response is preserved" do
    stop_reason_provider = Class.new(::RubyLLM::StubProvider) do
      def complete(messages, **kwargs)
        msg = ::RubyLLM::Message.new(role: :assistant, content: "Truncated")
        msg.stop_reason = "length"
        msg.input_tokens = 5
        msg.output_tokens = 100
        msg
      end
    end

    with_custom_provider(stop_reason_provider.new) do
      provider = ActiveAgent::Providers::RubyLLMProvider.new(
        service: "RubyLLM",
        model: "gpt-4o-mini",
        messages: [ { role: "user", content: "write a long essay" } ]
      )

      response = provider.prompt

      assert_equal "length", response.raw_response[:stop_reason]
    end
  end

  # --- Error handling ---

  test "handles error from RubyLLM Models.resolve" do
    ::RubyLLM::Models.stub(:resolve, ->(*_) { raise StandardError, "Model not found" }) do
      provider = ActiveAgent::Providers::RubyLLMProvider.new(
        service: "RubyLLM",
        model: "nonexistent-model",
        messages: [ { role: "user", content: "hello" } ]
      )

      assert_raises(StandardError) { provider.prompt }
    end
  end

  test "handles error from provider.complete" do
    error_provider = Class.new(::RubyLLM::StubProvider) do
      def complete(messages, **kwargs)
        raise StandardError, "API error"
      end
    end

    with_custom_provider(error_provider.new) do
      provider = ActiveAgent::Providers::RubyLLMProvider.new(
        service: "RubyLLM",
        model: "gpt-4o-mini",
        messages: [ { role: "user", content: "hello" } ]
      )

      assert_raises(StandardError) { provider.prompt }
    end
  end

  # --- max_tokens pass-through ---

  test "max_tokens is passed to provider via params" do
    capturing_provider = Class.new(::RubyLLM::StubProvider) do
      def complete(messages, **kwargs)
        @last_kwargs = kwargs
        msg = ::RubyLLM::Message.new(role: :assistant, content: "Short.")
        msg.input_tokens = 5
        msg.output_tokens = 2
        msg
      end

      def last_kwargs
        @last_kwargs
      end
    end

    custom = capturing_provider.new
    with_custom_provider(custom) do
      provider = ActiveAgent::Providers::RubyLLMProvider.new(
        service: "RubyLLM",
        model: "gpt-4o-mini",
        max_tokens: 256,
        messages: [ { role: "user", content: "hello" } ]
      )

      provider.prompt

      assert_equal({ max_tokens: 256 }, custom.last_kwargs[:params])
    end
  end

  test "max_tokens is not passed when not set" do
    response = @provider.prompt
    # Default StubProvider captures kwargs - params should not be set
    stub_provider = ::RubyLLM::Models.default_provider
    assert_nil stub_provider.last_kwargs[:params]
  end

  # --- ToolProxy conversion ---

  test "build_ruby_llm_tools converts common format tools" do
    tools = [
      {
        type: "function",
        function: {
          name: "get_weather",
          description: "Get weather for a location",
          parameters: {
            type: "object",
            properties: { location: { type: "string" } },
            required: [ "location" ]
          }
        }
      }
    ]

    result = @provider.send(:build_ruby_llm_tools, tools)

    assert_equal 1, result.size
    assert result.key?("get_weather")

    proxy = result["get_weather"]
    assert_equal "get_weather", proxy.name
    assert_equal "Get weather for a location", proxy.description
    assert_equal "object", proxy.parameters[:type]
  end

  test "build_ruby_llm_tools converts flat format tools" do
    tools = [
      {
        name: "search",
        description: "Search for items",
        parameters: { type: "object", properties: { query: { type: "string" } } }
      }
    ]

    result = @provider.send(:build_ruby_llm_tools, tools)

    assert_equal 1, result.size
    assert_equal "search", result["search"].name
  end

  test "build_ruby_llm_tools returns nil for empty tools" do
    assert_nil @provider.send(:build_ruby_llm_tools, nil)
    assert_nil @provider.send(:build_ruby_llm_tools, [])
  end

  test "ToolProxy params_schema returns string-keyed JSON schema" do
    proxy = ActiveAgent::Providers::RubyLLM::ToolProxy.new(
      name: "test",
      description: "A test tool",
      parameters: {
        type: "object",
        properties: { location: { type: "string", description: "City" } },
        required: [ "location" ]
      }
    )

    schema = proxy.params_schema
    assert_kind_of Hash, schema
    assert_equal "object", schema["type"]
    assert_equal "string", schema.dig("properties", "location", "type")
    assert_equal [ "location" ], schema["required"]
  end

  test "ToolProxy params_schema returns nil for empty parameters" do
    proxy = ActiveAgent::Providers::RubyLLM::ToolProxy.new(
      name: "test",
      description: "No params",
      parameters: {}
    )

    assert_nil proxy.params_schema
  end

  # --- convert_tool_calls_for_ruby_llm ---

  test "convert_tool_calls_for_ruby_llm converts function format" do
    tool_calls = [
      {
        id: "call_1",
        type: "function",
        function: { name: "get_weather", arguments: '{"location":"NYC"}' }
      }
    ]

    result = @provider.send(:convert_tool_calls_for_ruby_llm, tool_calls)

    assert_equal 1, result.size
    assert result.key?("call_1")
    assert_equal "get_weather", result["call_1"].name
    assert_equal '{"location":"NYC"}', result["call_1"].arguments
  end

  test "convert_tool_calls_for_ruby_llm converts flat format" do
    tool_calls = [
      { id: "call_1", name: "search", input: { query: "test" } }
    ]

    result = @provider.send(:convert_tool_calls_for_ruby_llm, tool_calls)

    assert_equal 1, result.size
    assert_equal "search", result["call_1"].name
  end

  test "convert_tool_calls_for_ruby_llm returns nil for nil" do
    assert_nil @provider.send(:convert_tool_calls_for_ruby_llm, nil)
  end

  private

  # Helper to swap the provider returned by Models.resolve for a test block.
  def with_custom_provider(provider_instance, &block)
    resolve_stub = ->(model_id, **_kwargs) { [ stub_model_info(model_id), provider_instance ] }
    ::RubyLLM::Models.stub(:resolve, resolve_stub, &block)
  end

  # Build a Model::Info compatible with both stub and real gem.
  def stub_model_info(model_id)
    ::RubyLLM::Model::Info.new(id: model_id, provider: "openai")
  end

  def tool_definition(name, description: "A test tool", parameters: nil)
    {
      type: "function",
      function: {
        name: name,
        description: description,
        parameters: parameters || {
          type: "object",
          properties: {
            location: { type: "string", description: "Location" }
          }
        }
      }
    }
  end
end
