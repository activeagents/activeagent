# frozen_string_literal: true

require "test_helper"

class LogSubscriberTest < ActiveSupport::TestCase
  setup do
    @original_logger = ActiveAgent.configuration.logger
    @original_colorize = ActiveAgent.configuration.colorize_logging
    @log_output = StringIO.new
    ActiveAgent.configuration.logger = Logger.new(@log_output)
    ActiveAgent.configuration.log_level = Logger::DEBUG
    ActiveAgent.configuration.colorize_logging = false
  end

  teardown do
    ActiveAgent.configuration.logger = @original_logger
    ActiveAgent.configuration.colorize_logging = @original_colorize
  end

  test "log subscriber is attached" do
    assert ActiveSupport::LogSubscriber.log_subscribers.any? { |s| s.is_a?(ActiveAgent::LogSubscriber) }
  end

  test "prompt_start event is logged" do
    ActiveSupport::Notifications.instrument("prompt_start.provider.active_agent", provider: "OpenAI")

    assert_match(/Starting prompt request/, @log_output.string)
    assert_match(/OpenAI/, @log_output.string)
  end

  test "embed_start event is logged" do
    ActiveSupport::Notifications.instrument("embed_start.provider.active_agent", provider: "OpenAI")

    assert_match(/Starting embed request/, @log_output.string)
    assert_match(/OpenAI/, @log_output.string)
  end

  test "request_prepared event is logged" do
    ActiveSupport::Notifications.instrument("request_prepared.provider.active_agent",
                                           provider: "Anthropic",
                                           message_count: 5)

    assert_match(/Prepared request with 5 message/, @log_output.string)
    assert_match(/Anthropic/, @log_output.string)
  end

  test "api_call event is logged with duration" do
    ActiveSupport::Notifications.instrument("api_call.provider.active_agent",
                                           provider: "OpenAI",
                                           streaming: true) do
      sleep 0.01 # Simulate some work
    end

    assert_match(/API call completed in \d+\.\d+ms/, @log_output.string)
    assert_match(/streaming: true/, @log_output.string)
  end

  test "stream_open event is logged" do
    ActiveSupport::Notifications.instrument("stream_open.provider.active_agent", provider: "Anthropic")

    assert_match(/Opening stream/, @log_output.string)
  end

  test "stream_close event is logged" do
    ActiveSupport::Notifications.instrument("stream_close.provider.active_agent", provider: "Anthropic")

    assert_match(/Closing stream/, @log_output.string)
  end

  test "messages_extracted event is logged" do
    ActiveSupport::Notifications.instrument("messages_extracted.provider.active_agent",
                                           provider: "OpenAI",
                                           message_count: 3)

    assert_match(/Extracted 3 message/, @log_output.string)
  end

  test "tool_calls_processing event is logged" do
    ActiveSupport::Notifications.instrument("tool_calls_processing.provider.active_agent",
                                           provider: "OpenAI",
                                           tool_count: 2)

    assert_match(/Processing 2 tool call/, @log_output.string)
  end

  test "multi_turn_continue event is logged" do
    ActiveSupport::Notifications.instrument("multi_turn_continue.provider.active_agent",
                                           provider: "Anthropic")

    assert_match(/Continuing multi-turn conversation/, @log_output.string)
  end

  test "prompt_complete event is logged with duration" do
    ActiveSupport::Notifications.instrument("prompt_complete.provider.active_agent",
                                           provider: "OpenAI",
                                           message_count: 4) do
      sleep 0.01 # Simulate some work
    end

    assert_match(/Prompt completed with 4 message/, @log_output.string)
    assert_match(/total: \d+\.\d+ms/, @log_output.string)
  end

  test "retry_attempt event is logged" do
    ActiveSupport::Notifications.instrument("retry_attempt.provider.active_agent",
                                           attempt: 2,
                                           max_retries: 3,
                                           exception: "TimeoutError",
                                           backoff_time: 2.5)

    assert_match(/Attempt 2\/3 failed with TimeoutError/, @log_output.string)
    assert_match(/retrying in 2.5s/, @log_output.string)
  end

  test "retry_exhausted event is logged" do
    ActiveSupport::Notifications.instrument("retry_exhausted.provider.active_agent",
                                           max_retries: 3,
                                           exception: "SocketError")

    assert_match(/Max retries \(3\) exceeded/, @log_output.string)
    assert_match(/SocketError/, @log_output.string)
  end

  test "logs nothing when logger level is above debug" do
    ActiveAgent.configuration.log_level = Logger::INFO

    ActiveSupport::Notifications.instrument("prompt_start.provider.active_agent", provider: "OpenAI")

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
end
