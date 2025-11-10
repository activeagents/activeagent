# frozen_string_literal: true

require "test_helper"
require "active_agent/providers/concerns/exception_handler"

module ActiveAgent
  module Providers
    class ExceptionHandlerTest < ActiveSupport::TestCase
      # Custom test exceptions
      class TestError < StandardError; end
      class CustomError < StandardError; end

      # Mock provider class for testing
      class MockProvider
        include ActiveAgent::Providers::ExceptionHandler

        attr_accessor :call_count, :error_to_raise

        def initialize(**options)
          @call_count = 0
          @error_to_raise = nil

          configure_exception_handler(
            exception_handler: options[:exception_handler]
          )
        end

        def perform_operation
          with_exception_handling do
            @call_count += 1
            raise error_to_raise if error_to_raise
            "success"
          end
        end
      end

      test "executes block successfully without errors" do
        provider = MockProvider.new
        result = provider.perform_operation

        assert_equal "success", result
        assert_equal 1, provider.call_count
      end

      test "re-raises exception when no handler configured" do
        provider = MockProvider.new
        provider.error_to_raise = TestError.new("test error")

        assert_raises(TestError) do
          provider.perform_operation
        end

        assert_equal 1, provider.call_count
      end

      test "calls exception handler when configured" do
        handled_exception = nil
        handler = ->(exception) { handled_exception = exception; "handled" }

        provider = MockProvider.new(exception_handler: handler)
        provider.error_to_raise = TestError.new("test error")

        result = provider.perform_operation

        assert_equal "handled", result
        assert_instance_of TestError, handled_exception
        assert_equal "test error", handled_exception.message
      end

      test "exception handler can return nil to allow re-raise" do
        handler = ->(_exception) { nil }

        provider = MockProvider.new(exception_handler: handler)
        provider.error_to_raise = TestError.new("test error")

        assert_raises(TestError) do
          provider.perform_operation
        end
      end

      test "handles different exception types" do
        handled_exceptions = []
        handler = ->(exception) {
          handled_exceptions << exception
          "handled #{exception.class.name}"
        }

        provider = MockProvider.new(exception_handler: handler)

        # Test with TestError
        provider.error_to_raise = TestError.new("test")
        result = provider.perform_operation
        assert_equal "handled ActiveAgent::Providers::ExceptionHandlerTest::TestError", result

        # Test with CustomError
        provider.error_to_raise = CustomError.new("custom")
        result = provider.perform_operation
        assert_equal "handled ActiveAgent::Providers::ExceptionHandlerTest::CustomError", result

        assert_equal 2, handled_exceptions.size
      end

      test "exception handler receives actual exception object" do
        provider = MockProvider.new(exception_handler: ->(e) { e })
        original_error = TestError.new("original message")
        provider.error_to_raise = original_error

        result = provider.perform_operation

        assert_same original_error, result
      end

      test "rescue_with_handler returns handler result" do
        provider = MockProvider.new(exception_handler: ->(_) { "custom result" })
        exception = TestError.new("test")

        result = provider.rescue_with_handler(exception)

        assert_equal "custom result", result
      end

      test "rescue_with_handler returns nil when no handler configured" do
        provider = MockProvider.new
        exception = TestError.new("test")

        result = provider.rescue_with_handler(exception)

        assert_nil result
      end
    end
  end
end
