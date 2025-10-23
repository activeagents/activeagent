# frozen_string_literal: true

require "test_helper"

class LogSubscriberTest < ActiveSupport::TestCase
  setup do
    @original_logger = ActiveAgent::Base.logger
    @original_colorize = ActiveAgent.configuration.colorize_logging
    @log_output = StringIO.new
    ActiveAgent::Base.logger = Logger.new(@log_output)
    ActiveAgent::Base.logger.level = Logger::DEBUG
    ActiveAgent.configuration.colorize_logging = false
  end

  teardown do
    ActiveAgent::Base.logger = @original_logger
    ActiveAgent.configuration.colorize_logging = @original_colorize
  end

  test "log subscriber is attached" do
    assert ActiveSupport::LogSubscriber.log_subscribers.any? { it.is_a?(ActiveAgent::LogSubscriber) }
  end

  test "prompt_start event is logged" do
    ActiveSupport::Notifications.instrument("prompt_start.provider.active_agent",
                                           provider: "OpenAI",
                                           provider_module: "OpenAI",
                                           trace_id: "test-123")

    assert_match(/Starting prompt request/, @log_output.string)
    assert_match(/OpenAI/, @log_output.string)
    assert_match(/test-123/, @log_output.string)
  end

  test "embed_start event is logged" do
    ActiveSupport::Notifications.instrument("embed_start.provider.active_agent",
                                           provider: "OpenAI",
                                           provider_module: "OpenAI",
                                           trace_id: "test-456")

    assert_match(/Starting embed request/, @log_output.string)
    assert_match(/OpenAI/, @log_output.string)
  end

  test "request_prepared event is logged" do
    ActiveSupport::Notifications.instrument("request_prepared.provider.active_agent",
                                           provider: "Anthropic",
                                           provider_module: "Anthropic",
                                           trace_id: "test-789",
                                           message_count: 5)

    assert_match(/Prepared request with 5 message/, @log_output.string)
    assert_match(/Anthropic/, @log_output.string)
  end

  test "api_call event is logged with duration" do
    ActiveSupport::Notifications.instrument("api_call.provider.active_agent",
                                           provider: "OpenAI",
                                           provider_module: "OpenAI",
                                           trace_id: "test-api",
                                           streaming: true) do
      sleep 0.01 # Simulate some work
    end

    assert_match(/API call completed in \d+\.\d+ms/, @log_output.string)
    assert_match(/streaming: true/, @log_output.string)
  end

  test "stream_open event is logged" do
    ActiveSupport::Notifications.instrument("stream_open.provider.active_agent",
                                           provider: "Anthropic",
                                           provider_module: "Anthropic",
                                           trace_id: "test-stream")

    assert_match(/Opening stream/, @log_output.string)
  end

  test "stream_close event is logged" do
    ActiveSupport::Notifications.instrument("stream_close.provider.active_agent",
                                           provider: "Anthropic",
                                           provider_module: "Anthropic",
                                           trace_id: "test-stream")

    assert_match(/Closing stream/, @log_output.string)
  end

  test "messages_extracted event is logged" do
    ActiveSupport::Notifications.instrument("messages_extracted.provider.active_agent",
                                           provider: "OpenAI",
                                           provider_module: "OpenAI",
                                           trace_id: "test-msg",
                                           message_count: 3)

    assert_match(/Extracted 3 message/, @log_output.string)
  end

  test "tool_calls_processing event is logged" do
    ActiveSupport::Notifications.instrument("tool_calls_processing.provider.active_agent",
                                           provider: "OpenAI",
                                           provider_module: "OpenAI",
                                           trace_id: "test-tool",
                                           tool_count: 2)

    assert_match(/Processing 2 tool call/, @log_output.string)
  end

  test "multi_turn_continue event is logged" do
    ActiveSupport::Notifications.instrument("multi_turn_continue.provider.active_agent",
                                           provider: "Anthropic",
                                           provider_module: "Anthropic",
                                           trace_id: "test-turn")

    assert_match(/Continuing multi-turn conversation/, @log_output.string)
  end

  test "prompt_complete event is logged with duration" do
    ActiveSupport::Notifications.instrument("prompt_complete.provider.active_agent",
                                           provider: "OpenAI",
                                           provider_module: "OpenAI",
                                           trace_id: "test-complete",
                                           message_count: 4) do
      sleep 0.01 # Simulate some work
    end

    assert_match(/Prompt completed with 4 message/, @log_output.string)
    assert_match(/total: \d+\.\d+ms/, @log_output.string)
  end

  test "retry_attempt event is logged" do
    ActiveSupport::Notifications.instrument("retry_attempt.provider.active_agent",
                                           provider_module: "OpenAI",
                                           attempt: 2,
                                           max_retries: 3,
                                           exception: "TimeoutError",
                                           backoff_time: 2.5)

    assert_match(/Attempt 2\/3 failed with TimeoutError/, @log_output.string)
    assert_match(/retrying in 2.5s/, @log_output.string)
  end

  test "retry_exhausted event is logged" do
    ActiveSupport::Notifications.instrument("retry_exhausted.provider.active_agent",
                                           provider_module: "OpenAI",
                                           max_retries: 3,
                                           exception: "SocketError")

    assert_match(/Max retries \(3\) exceeded/, @log_output.string)
    assert_match(/SocketError/, @log_output.string)
  end

  test "logs nothing when logger level is above debug" do
    ActiveAgent::Base.logger.level = Logger::INFO

    ActiveSupport::Notifications.instrument("prompt_start.provider.active_agent",
                                           provider: "OpenAI",
                                           provider_module: "OpenAI",
                                           trace_id: "test-level")

    assert_empty @log_output.string
  end

  test "custom subscriber can be attached" do
    events = []
    custom_subscriber = ->(event) { events << event }

    subscription = ActiveSupport::Notifications.subscribe("prompt_start.provider.active_agent", custom_subscriber)

    ActiveSupport::Notifications.instrument("prompt_start.provider.active_agent", provider: "Test")

    assert_equal 1, events.size
    assert_equal "prompt_start.provider.active_agent", events.first.name
    assert_equal "Test", events.first.payload[:provider]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  test "colorize_logging class accessor matches Rails pattern" do
    # Test that LogSubscriber has a class-level accessor
    assert_respond_to ActiveAgent::LogSubscriber, :colorize_logging
    assert_respond_to ActiveAgent::LogSubscriber, :colorize_logging=

    # Test setting directly on the class
    original = ActiveAgent::LogSubscriber.colorize_logging
    ActiveAgent::LogSubscriber.colorize_logging = false
    assert_equal false, ActiveAgent::LogSubscriber.colorize_logging

    # Test that configuration setter syncs with LogSubscriber
    ActiveAgent.configuration.colorize_logging = true
    assert_equal true, ActiveAgent::LogSubscriber.colorize_logging

    # Restore original
    ActiveAgent::LogSubscriber.colorize_logging = original
  end
end
