# frozen_string_literal: true

require "test_helper"

class LogSubscriberTest < ActiveSupport::TestCase
  setup do
    @original_logger = ActiveAgent::Base.logger
    @log_output = StringIO.new
    ActiveAgent::Base.logger = Logger.new(@log_output)
    ActiveAgent::Base.logger.level = Logger::DEBUG
  end

  teardown do
    ActiveAgent::Base.logger = @original_logger
  end

  test "log subscriber is attached" do
    assert ActiveSupport::LogSubscriber.log_subscribers.any? { _1.is_a?(ActiveAgent::Providers::LogSubscriber) }
  end

  test "prompt event is logged with model and message count" do
    ActiveSupport::Notifications.instrument("prompt.active_agent",
                                           trace_id: "test-123",
                                           provider_module: "OpenAI",
                                           model: "gpt-4",
                                           message_count: 3,
                                           stream: false,
                                           finish_reason: "stop") do
      sleep 0.01 # Simulate work for duration
    end

    assert_match(/\[test-123\]/, @log_output.string)
    assert_match(/\[ActiveAgent\]/, @log_output.string)
    assert_match(/\[OpenAI\]/, @log_output.string)
    assert_match(/Prompt completed:/, @log_output.string)
    assert_match(/model=gpt-4/, @log_output.string)
    assert_match(/messages=3/, @log_output.string)
    assert_match(/stream=false/, @log_output.string)
    assert_match(/finish=stop/, @log_output.string)
    assert_match(/\d+\.\d+ms/, @log_output.string)
  end

  test "prompt event includes usage information" do
    ActiveSupport::Notifications.instrument("prompt.active_agent",
                                           trace_id: "test-usage",
                                           provider_module: "Anthropic",
                                           model: "claude-3-5-sonnet-20241022",
                                           message_count: 2,
                                           stream: false,
                                           usage: {
                                             input_tokens: 100,
                                             output_tokens: 50,
                                             cached_tokens: 25,
                                             reasoning_tokens: 10
                                           })

    assert_match(/tokens=100\/50/, @log_output.string)
    assert_match(/cached: 25/, @log_output.string)
    assert_match(/reasoning: 10/, @log_output.string)
  end

  test "embed event is logged with model and input size" do
    ActiveSupport::Notifications.instrument("embed.active_agent",
                                           trace_id: "test-456",
                                           provider_module: "OpenAI",
                                           model: "text-embedding-ada-002",
                                           input_size: 5,
                                           embedding_count: 5,
                                           usage: { input_tokens: 150 }) do
      sleep 0.01 # Simulate work
    end

    assert_match(/\[test-456\]/, @log_output.string)
    assert_match(/\[OpenAI\]/, @log_output.string)
    assert_match(/Embed completed:/, @log_output.string)
    assert_match(/model=text-embedding-ada-002/, @log_output.string)
    assert_match(/inputs=5/, @log_output.string)
    assert_match(/embeddings=5/, @log_output.string)
    assert_match(/tokens=150/, @log_output.string)
  end

  test "stream_open event is logged" do
    ActiveSupport::Notifications.instrument("stream_open.active_agent",
                                           trace_id: "test-stream",
                                           provider_module: "Anthropic")

    assert_match(/\[test-stream\]/, @log_output.string)
    assert_match(/\[Anthropic\]/, @log_output.string)
    assert_match(/Opening stream/, @log_output.string)
  end

  test "stream_close event is logged" do
    ActiveSupport::Notifications.instrument("stream_close.active_agent",
                                           trace_id: "test-stream",
                                           provider_module: "Anthropic")

    assert_match(/\[test-stream\]/, @log_output.string)
    assert_match(/\[Anthropic\]/, @log_output.string)
    assert_match(/Closing stream/, @log_output.string)
  end

  test "tool_call event is logged" do
    ActiveSupport::Notifications.instrument("tool_call.active_agent",
                                           trace_id: "test-tool",
                                           provider_module: "Anthropic",
                                           tool_name: "weather_lookup") do
      sleep 0.01 # Simulate work
    end

    assert_match(/\[test-tool\]/, @log_output.string)
    assert_match(/\[Anthropic\]/, @log_output.string)
    assert_match(/Tool call: weather_lookup/, @log_output.string)
    assert_match(/\d+\.\d+ms/, @log_output.string)
  end

  test "stream_chunk event is logged" do
    ActiveSupport::Notifications.instrument("stream_chunk.active_agent",
                                           trace_id: "test-chunk",
                                           provider_module: "Anthropic",
                                           chunk_type: "content_block_delta")

    assert_match(/\[test-chunk\]/, @log_output.string)
    assert_match(/\[Anthropic\]/, @log_output.string)
    assert_match(/Stream chunk: content_block_delta/, @log_output.string)
  end

  test "stream_chunk event without chunk_type" do
    ActiveSupport::Notifications.instrument("stream_chunk.active_agent",
                                           trace_id: "test-chunk2",
                                           provider_module: "OpenAI")

    assert_match(/Stream chunk/, @log_output.string)
    refute_match(/Stream chunk:/, @log_output.string)
  end

  test "connection_error event is logged" do
    ActiveSupport::Notifications.instrument("connection_error.active_agent",
                                           trace_id: "test-error",
                                           provider_module: "Ollama",
                                           uri_base: "http://localhost:11434",
                                           exception: "Errno::ECONNREFUSED",
                                           message: "Connection refused")

    assert_match(/\[test-error\]/, @log_output.string)
    assert_match(/\[Ollama\]/, @log_output.string)
    assert_match(/Unable to connect to http:\/\/localhost:11434/, @log_output.string)
    assert_match(/Errno::ECONNREFUSED/, @log_output.string)
    assert_match(/Connection refused/, @log_output.string)
  end

  test "logs nothing when logger level is above debug" do
    ActiveAgent::Base.logger.level = Logger::INFO

    ActiveSupport::Notifications.instrument("prompt.active_agent",
                                           trace_id: "test-level",
                                           provider_module: "OpenAI",
                                           model: "gpt-4",
                                           message_count: 1,
                                           stream: false)

    assert_empty @log_output.string
  end

  test "custom subscriber can be attached" do
    events = []
    custom_subscriber = ->(event) { events << event }

    subscription = ActiveSupport::Notifications.subscribe("prompt.active_agent", custom_subscriber)

    ActiveSupport::Notifications.instrument("prompt.active_agent",
                                           trace_id: "test-custom",
                                           provider_module: "Test",
                                           message_count: 1,
                                           stream: false)

    assert_equal 1, events.size
    assert_equal "prompt.active_agent", events.first.name
    assert_equal "Test", events.first.payload[:provider_module]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end
end
