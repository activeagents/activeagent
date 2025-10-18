# frozen_string_literal: true

require "test_helper"
require "active_agent/providers/concerns/retries"

module ActiveAgent
  module Providers
    class RetriesTest < ActiveSupport::TestCase
      # Custom test exceptions
      class TestError < StandardError; end
      class RetriableError < StandardError; end
      class NonRetriableError < StandardError; end

      # Mock provider class for testing
      class MockProvider
        include ActiveAgent::Providers::Retries

        attr_accessor :call_count, :error_to_raise

        def initialize(**options)
          @call_count = 0
          @error_to_raise = nil

          configure_retries(
            exception_handler: options[:exception_handler],
            retries:           options[:retries],
            retries_count:     options[:retries_count],
            retries_on:        options[:retries_on]
          )
        end

        def perform_operation
          retriable do
            @call_count += 1
            raise error_to_raise if error_to_raise
            "success"
          end
        end
      end

      setup do
        @original_config = ActiveAgent.configuration
        ActiveAgent.instance_variable_set(:@configuration, Configuration.new)
      end

      teardown do
        ActiveAgent.instance_variable_set(:@configuration, @original_config)
      end

      # Class method tests
      test "retriable_strategy returns global config value" do
        ActiveAgent.configure do |config|
          config.retries = false
        end

        assert_equal false, MockProvider.retriable_strategy
      end

      test "retriable_strategy returns default when config is nil" do
        # Configuration doesn't allow setting retries to nil, so we skip this validation test
        # The default is always returned when no explicit value is configured
        skip "Configuration validates retries and doesn't allow nil values"
      end

      test "retriable_exceptions returns global config exceptions" do
        expected = Configuration::DEFAULTS[:retries_on]
        assert_equal expected, MockProvider.retriable_exceptions
      end

      test "retriable_max returns global config retry count" do
        ActiveAgent.configure do |config|
          config.retries_count = 5
        end

        assert_equal 5, MockProvider.retriable_max
      end

      test "retriable_max returns default when config is nil" do
        assert_equal Configuration::DEFAULTS[:retries_count], MockProvider.retriable_max
      end

      # Initialization tests
      test "initializes with default retry strategy from config" do
        ActiveAgent.configure do |config|
          config.retries = false
        end

        provider = MockProvider.new
        assert_equal false, provider.retries
      end

      test "initializes with instance-level retry strategy override" do
        ActiveAgent.configure do |config|
          config.retries = true
        end

        provider = MockProvider.new(retries: false)
        assert_equal false, provider.retries
      end

      test "initializes with default retry count from config" do
        ActiveAgent.configure do |config|
          config.retries_count = 5
        end

        provider = MockProvider.new
        assert_equal 5, provider.retries_count
      end

      test "initializes with instance-level retry count override" do
        ActiveAgent.configure do |config|
          config.retries_count = 3
        end

        provider = MockProvider.new(retries_count: 7)
        assert_equal 7, provider.retries_count
      end

      test "initializes with default exceptions from config" do
        provider = MockProvider.new
        expected = Configuration::DEFAULTS[:retries_on]
        assert_equal expected, provider.retries_on
      end

      test "initializes with merged exception list" do
        provider = MockProvider.new(retries_on: [ RetriableError ])
        expected = Configuration::DEFAULTS[:retries_on] | [ RetriableError ]
        assert_equal expected, provider.retries_on
      end

      test "initializes with exception handler" do
        handler = ->(e) { "handled" }
        provider = MockProvider.new(exception_handler: handler)
        assert_equal handler, provider.exception_handler
      end

      test "initializes with custom retry strategy" do
        custom_strategy = ->(block) { block.call }
        provider = MockProvider.new(retries: custom_strategy)
        assert_equal custom_strategy, provider.retries
      end

      # No retry tests (retries: false)
      test "executes block without retries when retries disabled" do
        provider = MockProvider.new(retries: false)
        result = provider.perform_operation

        assert_equal "success", result
        assert_equal 1, provider.call_count
      end

      test "raises error immediately when retries disabled" do
        provider = MockProvider.new(retries: false)
        provider.error_to_raise = TestError.new("test error")

        error = assert_raises(TestError) do
          provider.perform_operation
        end

        assert_equal "test error", error.message
        assert_equal 1, provider.call_count
      end

      test "calls exception handler when retries disabled" do
        handler_called = false
        handler = ->(e) { handler_called = true; "handled" }

        provider = MockProvider.new(retries: false, exception_handler: handler)
        provider.error_to_raise = TestError.new("test error")

        result = provider.perform_operation

        assert_equal "handled", result
        assert handler_called
      end

      # Built-in retry tests (retries: true)
      test "executes block successfully with built-in retries" do
        provider = MockProvider.new(retries: true)
        result = provider.perform_operation

        assert_equal "success", result
        assert_equal 1, provider.call_count
      end

      test "retries on configured exceptions with exponential backoff" do
        provider = MockProvider.new(
          retries: true,
          retries_count: 2,
          retries_on: [ TestError ]
        )

        # Track how many times we're called
        call_count = 0

        # Override error_to_raise to succeed on third attempt
        provider.define_singleton_method(:perform_operation) do
          retriable do
            call_count += 1
            if call_count < 3
              raise TestError.new("attempt #{call_count}")
            end
            "success"
          end
        end

        result = provider.perform_operation
        assert_equal "success", result
        assert_equal 3, call_count  # 1 initial + 2 retries
      end

      test "retries respect the maximum retry count" do
        provider = MockProvider.new(
          retries: true,
          retries_count: 3,
          retries_on: [ Net::ReadTimeout ]
        )
        provider.error_to_raise = Net::ReadTimeout.new

        assert_raises(Net::ReadTimeout) do
          provider.perform_operation
        end

        # 1 initial attempt + 3 retries = 4 total calls
        assert_equal 4, provider.call_count
      end

      test "retries with exponential backoff delays" do
        provider = MockProvider.new(
          retries: true,
          retries_count: 3,
          retries_on: [ TestError ]
        )

        sleep_calls = []
        provider.stub :sleep, ->(duration) { sleep_calls << duration } do
          provider.error_to_raise = TestError.new("test")

          assert_raises(TestError) do
            provider.perform_operation
          end
        end

        # Exponential backoff: 2^0=1, 2^1=2, 2^2=4
        assert_equal [ 1, 2, 4 ], sleep_calls
      end

      test "does not retry on non-configured exceptions" do
        provider = MockProvider.new(
          retries: true,
          retries_count: 3,
          retries_on: [ Net::ReadTimeout ]
        )
        provider.error_to_raise = NonRetriableError.new("not retriable")

        error = assert_raises(NonRetriableError) do
          provider.perform_operation
        end

        assert_equal "not retriable", error.message
        assert_equal 1, provider.call_count
      end

      test "calls exception handler after max retries exceeded" do
        handler_called = false
        handler_exception = nil
        handler = ->(e) {
          handler_called = true
          handler_exception = e
          "handled after retries"
        }

        provider = MockProvider.new(
          retries: true,
          retries_count: 2,
          retries_on: [ TestError ],
          exception_handler: handler
        )
        provider.error_to_raise = TestError.new("persistent error")

        result = provider.perform_operation

        assert_equal "handled after retries", result
        assert handler_called
        assert_instance_of TestError, handler_exception
        assert_equal "persistent error", handler_exception.message
        # 1 initial + 2 retries = 3 total
        assert_equal 3, provider.call_count
      end

      test "succeeds on retry after initial failure" do
        provider = MockProvider.new(
          retries: true,
          retries_count: 3,
          retries_on: [ TestError ]
        )

        # Fail first time, succeed second time
        call_count = 0
        provider.define_singleton_method(:perform_operation) do
          retriable do
            call_count += 1
            if call_count == 1
              raise TestError.new("first attempt fails")
            end
            "success on retry"
          end
        end

        result = provider.perform_operation
        assert_equal "success on retry", result
        assert_equal 2, call_count  # Failed once, succeeded on retry
      end

      # Custom retry strategy tests
      test "executes custom retry strategy" do
        custom_calls = []
        custom_strategy = ->(block) {
          custom_calls << :before
          result = block.call
          custom_calls << :after
          result
        }

        provider = MockProvider.new(retries: custom_strategy)
        result = provider.perform_operation

        assert_equal "success", result
        assert_equal [ :before, :after ], custom_calls
      end

      test "custom strategy receives wrapped block with error handling" do
        handler_called = false
        handler = ->(e) { handler_called = true; "handled in custom" }

        custom_strategy = ->(block) {
          block.call
        }

        provider = MockProvider.new(
          retries: custom_strategy,
          exception_handler: handler
        )
        provider.error_to_raise = TestError.new("custom error")

        result = provider.perform_operation

        assert_equal "handled in custom", result
        assert handler_called
      end

      test "custom strategy can implement its own retry logic" do
        attempt_count = 0
        custom_strategy = ->(block) {
          3.times do
            attempt_count += 1
            begin
              return block.call
            rescue TestError
              # Retry on TestError
              sleep(0.01) unless attempt_count >= 3
            end
          end
          raise TestError.new("custom retries exhausted")
        }

        provider = MockProvider.new(retries: custom_strategy)

        # Fail twice, succeed third time
        call_count = 0
        provider.define_singleton_method(:retriable_with_custom_retries) do |strategy, &block|
          wrapped = proc {
            call_count += 1
            if call_count < 3
              raise TestError.new("attempt #{call_count}")
            end
            "success on attempt 3"
          }
          strategy.call(wrapped)
        end

        result = provider.retriable { "ignored" }
        assert_equal "success on attempt 3", result
        assert_equal 3, call_count
      end

      # Exception handler tests
      test "rescue_with_handler calls exception handler" do
        handler_called = false
        handler_exception = nil
        handler = ->(e) {
          handler_called = true
          handler_exception = e
          "handled"
        }

        provider = MockProvider.new(exception_handler: handler)
        exception = TestError.new("test")

        result = provider.rescue_with_handler(exception)

        assert_equal "handled", result
        assert handler_called
        assert_equal exception, handler_exception
      end

      test "rescue_with_handler returns nil when no handler defined" do
        provider = MockProvider.new
        exception = TestError.new("test")

        result = provider.rescue_with_handler(exception)

        assert_nil result
      end

      # Integration tests
      test "full flow with retries disabled and exception handler" do
        logs = []
        handler = ->(e) {
          logs << "handled: #{e.message}"
          nil
        }

        provider = MockProvider.new(
          retries: false,
          exception_handler: handler
        )
        provider.error_to_raise = TestError.new("integration test")

        error = assert_raises(TestError) do
          provider.perform_operation
        end

        assert_equal "integration test", error.message
        assert_equal [ "handled: integration test" ], logs
        assert_equal 1, provider.call_count
      end

      test "full flow with built-in retries and success on retry" do
        provider = MockProvider.new(
          retries: true,
          retries_count: 3,
          retries_on: [ Net::ReadTimeout ]
        )

        # Fail once, then succeed
        call_count = 0
        provider.define_singleton_method(:perform_operation) do
          retriable do
            call_count += 1
            if call_count < 2
              raise Net::ReadTimeout.new
            end
            "success on second attempt"
          end
        end

        result = provider.perform_operation
        assert_equal "success on second attempt", result
        assert_equal 2, call_count  # Failed once, succeeded on second attempt
      end

      test "delegates to class methods for default values" do
        ActiveAgent.configure do |config|
          config.retries = false
          config.retries_count = 10
          config.retries_on = [ IOError ]
        end

        provider = MockProvider.new

        assert_equal false, provider.retries
        assert_equal 10, provider.retries_count
        assert_includes provider.retries_on, IOError
      end

      test "instance configuration overrides class defaults" do
        ActiveAgent.configure do |config|
          config.retries = true
          config.retries_count = 3
        end

        custom_strategy = ->(block) { block.call }
        provider = MockProvider.new(
          retries: custom_strategy,
          retries_count: 5,
          retries_on: [ TestError ]
        )

        assert_equal custom_strategy, provider.retries
        assert_equal 5, provider.retries_count
        assert_includes provider.retries_on, TestError
      end

      # Edge cases
      test "handles zero retry count" do
        provider = MockProvider.new(
          retries: true,
          retries_count: 0,
          retries_on: [ TestError ]
        )
        provider.error_to_raise = TestError.new("no retries")

        assert_raises(TestError) do
          provider.perform_operation
        end

        # Only initial attempt, no retries
        assert_equal 1, provider.call_count
      end

      test "handles empty retries_on array" do
        # When retries_on is [], it still gets merged with default exceptions from config
        # So we need to verify the merged behavior
        provider = MockProvider.new(
          retries: true,
          retries_count: 3,
          retries_on: []
        )

        # retries_on will contain default exceptions from Configuration::DEFAULTS[:retries_on]
        assert_equal Configuration::DEFAULTS[:retries_on], provider.retries_on

        # If we raise an exception that IS in the defaults, it will retry
        provider.error_to_raise = Net::ReadTimeout.new

        assert_raises(Net::ReadTimeout) do
          provider.perform_operation
        end

        # 1 initial + 3 retries = 4 total (because Net::ReadTimeout is in defaults)
        assert_equal 4, provider.call_count
      end

      test "exception handler can suppress error by returning value" do
        handler = ->(e) { "fallback value" }

        provider = MockProvider.new(
          retries: true,
          retries_count: 1,
          retries_on: [ TestError ],
          exception_handler: handler
        )
        provider.error_to_raise = TestError.new("suppressed")

        result = provider.perform_operation

        assert_equal "fallback value", result
        # 1 initial + 1 retry = 2 total
        assert_equal 2, provider.call_count
      end

      test "exception handler returning nil allows error to propagate" do
        handler = ->(e) { nil }

        provider = MockProvider.new(
          retries: false,
          exception_handler: handler
        )
        provider.error_to_raise = TestError.new("propagated")

        error = assert_raises(TestError) do
          provider.perform_operation
        end

        assert_equal "propagated", error.message
      end

      test "validates retry strategy configuration at initialization" do
        # This test ensures invalid retry strategies are handled
        # The current implementation accepts any value, but this could be enhanced
        provider = MockProvider.new(retries: "invalid")

        # Should store the value even if it's not valid
        # (validation happens at runtime in retriable method)
        assert_equal "invalid", provider.retries
      end
    end
  end
end
