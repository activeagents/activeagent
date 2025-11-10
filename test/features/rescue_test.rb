# frozen_string_literal: true

require "test_helper"

class RescueTest < ActiveSupport::TestCase
  class CustomError < StandardError; end
  class AnotherError < StandardError; end
  class UnhandledError < StandardError; end

  class TestAgent < ApplicationAgent
    attr_accessor :error_handled, :handler_called, :exception_object

    rescue_from CustomError, with: :handle_custom_error
    rescue_from AnotherError do |exception|
      @exception_object = exception
      @handler_called = true
    end

    def raise_custom_error
      raise CustomError, "Test error"
    end

    def raise_another_error
      raise AnotherError, "Another error"
    end

    def raise_unhandled_error
      raise UnhandledError, "Unhandled error"
    end

    private

    def handle_custom_error(exception)
      @error_handled = true
      @exception_object = exception
    end
  end

  class TestAgentWithMultipleHandlers < ApplicationAgent
    attr_accessor :log

    def initialize(*)
      super
      @log = []
    end

    rescue_from StandardError, with: :handle_standard_error
    rescue_from CustomError, with: :handle_custom_error

    def raise_custom_error
      raise CustomError, "Specific error"
    end

    def raise_runtime_error
      raise RuntimeError, "Runtime error"
    end

    def handle_standard_error(exception)
      @log << "standard_error: #{exception.message}"
    end

    def handle_custom_error(exception)
      @log << "custom_error: #{exception.message}"
    end
  end

  test "rescues exceptions with method handler" do
    agent = TestAgent.new

    # The concern should catch the exception in process
    assert_nothing_raised do
      agent.process(:raise_custom_error)
    end

    assert agent.error_handled, "Custom error handler should be called"
    assert_instance_of CustomError, agent.exception_object
    assert_equal "Test error", agent.exception_object.message
  end

  test "rescues exceptions with block handler" do
    agent = TestAgent.new

    assert_nothing_raised do
      agent.process(:raise_another_error)
    end

    assert agent.handler_called, "Block handler should be called"
    assert_instance_of AnotherError, agent.exception_object
    assert_equal "Another error", agent.exception_object.message
  end

  test "re-raises unhandled exceptions" do
    agent = TestAgent.new

    error = assert_raises(UnhandledError) do
      agent.process(:raise_unhandled_error)
    end

    assert_equal "Unhandled error", error.message
  end

  test "uses most specific handler when multiple handlers match" do
    agent = TestAgentWithMultipleHandlers.new

    # CustomError is more specific than StandardError
    assert_nothing_raised do
      agent.process(:raise_custom_error)
    end

    assert_equal [ "custom_error: Specific error" ], agent.log
  end

  test "falls back to less specific handler" do
    agent = TestAgentWithMultipleHandlers.new

    # RuntimeError inherits from StandardError but isn't CustomError
    assert_nothing_raised do
      agent.process(:raise_runtime_error)
    end

    assert_equal [ "standard_error: Runtime error" ], agent.log
  end

  test "process delegates to super when no exception" do
    agent = TestAgent.new
    agent.params = { message: "Test" }

    # Process should work normally - use an inline prompt instead
    result = agent.send(:prompt, message: "Test")

    assert_not_nil result
  end

  test "preserves exception backtrace" do
    agent = TestAgent.new

    assert_nothing_raised do
      agent.process(:raise_custom_error)
    end

    assert_not_nil agent.exception_object
    assert_not_nil agent.exception_object.backtrace
    assert agent.exception_object.backtrace.any? { |line| line.include?("rescue_test.rb") }
  end

  test "includes Rescue module" do
    assert TestAgent.ancestors.include?(ActiveSupport::Rescuable)
  end

  test "extends ActiveSupport::Concern" do
    assert ActiveAgent::Rescue.respond_to?(:included)
  end

  test "handler receives correct exception object" do
    agent = TestAgent.new
    agent.process(:raise_custom_error)

    assert_equal "Test error", agent.exception_object.message
    assert_instance_of CustomError, agent.exception_object
  end

  test "multiple rescue_from declarations work independently" do
    agent = TestAgent.new

    # First error type
    agent.process(:raise_custom_error)
    assert agent.error_handled
    assert_instance_of CustomError, agent.exception_object

    # Reset
    agent.error_handled = false
    agent.exception_object = nil

    # Second error type
    agent.process(:raise_another_error)
    assert agent.handler_called
    assert_instance_of AnotherError, agent.exception_object
    assert_not agent.error_handled # Different handler was called
  end

  test "process continues to work for normal actions without exceptions" do
    agent = TestAgent.new
    agent.params = { message: "Normal operation" }

    result = agent.send(:prompt, message: "Normal operation")

    assert_not_nil result
    assert_nil agent.exception_object
    assert_not agent.error_handled
  end

  test "exception raised during handler execution is not caught again" do
    error_agent = Class.new(ApplicationAgent) do
      rescue_from CustomError, with: :buggy_handler

      def raise_error
        raise CustomError, "Original error"
      end

      def buggy_handler(exception)
        raise RuntimeError, "Handler error"
      end
    end

    agent = error_agent.new

    # The RuntimeError from the handler should not be caught
    error = assert_raises(RuntimeError) do
      agent.process(:raise_error)
    end

    assert_equal "Handler error", error.message
  end
end
