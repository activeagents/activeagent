# frozen_string_literal: true

require "test_helper"
require "ostruct"
require "active_agent/action_prompt/message"
require "active_agent/generation_provider/response"
require "active_agent/generation_provider/stream_processing"

class StreamProcessingTest < ActiveSupport::TestCase
  class TestProvider
    include ActiveAgent::GenerationProvider::StreamProcessing

    attr_accessor :prompt, :config, :response

    def initialize(prompt = nil)
      @prompt = prompt
      @stream_chunks = []
      @response = nil
    end

    # Override for testing
    def process_stream_chunk(chunk, message, agent_stream)
      @stream_chunks << chunk

      if chunk[:content]
        message.content += chunk[:content]
        agent_stream&.call(message, chunk[:content], false, prompt&.action_name)
      end

      if chunk[:finish]
        finalize_stream(message, agent_stream)
      end
    end

    attr_reader :stream_chunks
  end

  setup do
    @prompt = OpenStruct.new(
      options: { stream: true },
      action_name: "test_action"
    )
    @provider = TestProvider.new(@prompt)
  end

  test "provider_stream creates a proc" do
    stream_proc = @provider.provider_stream
    assert_instance_of Proc, stream_proc
  end

  test "provider_stream initializes response" do
    stream_proc = @provider.provider_stream
    assert_not_nil @provider.response
    assert_instance_of ActiveAgent::GenerationProvider::Response, @provider.response
  end

  test "initialize_stream_message creates assistant message" do
    message = @provider.send(:initialize_stream_message)
    assert_equal :assistant, message.role
    assert_equal "", message.content
  end

  test "process_stream_chunk raises NotImplementedError by default" do
    class DefaultProvider
      include ActiveAgent::GenerationProvider::StreamProcessing
    end

    provider = DefaultProvider.new
    assert_raises(NotImplementedError) do
      provider.send(:process_stream_chunk, {}, nil, nil)
    end
  end

  test "handle_stream_delta processes content delta" do
    message = ActiveAgent::ActionPrompt::Message.new(content: "", role: :assistant)
    chunks_received = []

    agent_stream = proc do |msg, content, finished, action|
      chunks_received << { message: msg, content: content, finished: finished }
    end

    @provider.send(:handle_stream_delta, "Hello", message, agent_stream)

    assert_equal "Hello", message.content
    assert_equal 1, chunks_received.length
    assert_equal "Hello", chunks_received[0][:content]
    assert_equal false, chunks_received[0][:finished]
  end

  test "finalize_stream calls agent_stream with finished flag" do
    message = ActiveAgent::ActionPrompt::Message.new(content: "Test", role: :assistant)
    finalized = false

    agent_stream = proc do |msg, content, finished, action|
      finalized = finished if finished
    end

    @provider.send(:finalize_stream, message, agent_stream)
    assert finalized
  end

  test "extract_content_from_delta handles string content" do
    assert_equal "test", @provider.send(:extract_content_from_delta, "test")
    assert_nil @provider.send(:extract_content_from_delta, { content: "test" })
    assert_nil @provider.send(:extract_content_from_delta, nil)
  end

  test "streaming workflow with multiple chunks" do
    chunks_received = []
    agent_stream = proc do |msg, content, finished, action|
      chunks_received << {
        content: content,
        finished: finished,
        total: msg.content
      }
    end

    @prompt.options[:stream] = agent_stream
    stream_proc = @provider.provider_stream

    # Simulate streaming chunks
    stream_proc.call({ content: "Hello" })
    stream_proc.call({ content: " world" })
    stream_proc.call({ finish: true })

    assert_equal 3, chunks_received.length
    assert_equal "Hello", chunks_received[0][:content]
    assert_equal " world", chunks_received[1][:content]
    assert_nil chunks_received[2][:content]
    assert chunks_received[2][:finished]
    assert_equal "Hello world", chunks_received[2][:total]
  end

  test "handle_tool_stream_chunk can be overridden" do
    class ToolProvider < TestProvider
      def handle_tool_stream_chunk(chunk, message, agent_stream)
        message.content = "Tool handled"
      end
    end

    provider = ToolProvider.new(@prompt)
    message = ActiveAgent::ActionPrompt::Message.new(content: "", role: :assistant)

    provider.send(:handle_tool_stream_chunk, {}, message, nil)
    assert_equal "Tool handled", message.content
  end

  test "stream_buffer and stream_context attributes" do
    @provider.stream_buffer = "buffer"
    @provider.stream_context = { test: true }

    assert_equal "buffer", @provider.stream_buffer
    assert_equal({ test: true }, @provider.stream_context)
  end
end
