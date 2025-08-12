# frozen_string_literal: true

require "test_helper"
require "active_support/rescuable"
require "active_agent/generation_provider/base"
require "active_agent/generation_provider/error_handling"

class ErrorHandlingTest < ActiveSupport::TestCase
  class TestError < StandardError; end
  class RetryableError < StandardError; end
  
  class TestProvider
    include ActiveAgent::GenerationProvider::ErrorHandling
    
    attr_accessor :config, :call_count
    
    def initialize(config = {})
      @config = config
      @call_count = 0
    end
    
    def operation_that_fails
      @call_count += 1
      raise TestError, "Test error message"
    end
    
    def operation_that_succeeds_on_retry
      @call_count += 1
      if @call_count < 2
        raise RetryableError, "Temporary failure"
      else
        "Success"
      end
    end
  end
  
  setup do
    @provider = TestProvider.new
    # Ensure verbose errors are disabled for these tests
    @provider.class.verbose_errors_enabled = false
  end
  
  test "with_error_handling uses rescue_with_handler" do
    # The default rescue_from StandardError handler will convert to GenerationProviderError
    error = assert_raises(ActiveAgent::GenerationProvider::Base::GenerationProviderError) do
      @provider.with_error_handling do
        @provider.operation_that_fails
      end
    end
    
    assert_equal "Test error message", error.message
  end
  
  test "preserves original backtrace" do
    original_line = nil
    error = assert_raises(ActiveAgent::GenerationProvider::Base::GenerationProviderError) do
      @provider.with_error_handling do
        original_line = __LINE__ + 1
        raise TestError, "With backtrace"
      end
    end
    
    assert error.backtrace.any? { |line| line.include?("#{__FILE__}:#{original_line}") }
  end
  
  test "retries on configured errors" do
    @provider.class.retry_on_errors = [RetryableError]
    @provider.class.max_retries = 3
    
    result = @provider.with_error_handling do
      @provider.operation_that_succeeds_on_retry
    end
    
    assert_equal "Success", result
    assert_equal 2, @provider.call_count
  end
  
  test "respects max_retries limit" do
    @provider.class.retry_on_errors = [TestError]
    @provider.class.max_retries = 2
    
    assert_raises(ActiveAgent::GenerationProvider::Base::GenerationProviderError) do
      @provider.with_error_handling do
        @provider.operation_that_fails
      end
    end
    
    assert_equal 3, @provider.call_count # Initial + 2 retries
  end
  
  test "should_retry? checks error class" do
    @provider.class.retry_on_errors = [RetryableError]
    
    assert @provider.send(:should_retry?, RetryableError.new)
    assert_not @provider.send(:should_retry?, TestError.new)
  end
  
  test "retry_delay uses exponential backoff" do
    assert_equal 1, @provider.send(:retry_delay, 1)
    assert_equal 2, @provider.send(:retry_delay, 2)
    assert_equal 4, @provider.send(:retry_delay, 3)
    assert_equal 8, @provider.send(:retry_delay, 4)
  end
  
  test "format_error_message handles different error types" do
    error_with_message = StandardError.new("Standard message")
    assert_equal "Standard message", @provider.send(:format_error_message, error_with_message)
    
    # Test with an object that doesn't respond to message
    error_without_message = Object.new
    def error_without_message.to_s
      "custom object string"
    end
    message = @provider.send(:format_error_message, error_without_message)
    assert_equal "custom object string", message
    
    # Test with an object that doesn't respond to to_s properly
    class NoMethodObject; end
    no_method_obj = NoMethodObject.new
    message = @provider.send(:format_error_message, no_method_obj)
    assert_match(/NoMethodObject/, message)
  end
  
  test "verbose_errors includes error class in message" do
    @provider.class.verbose_errors_enabled = true
    error = StandardError.new("Test")
    
    message = @provider.send(:format_error_message, error)
    assert_equal "[StandardError] Test", message
  end
  
  test "verbose_errors? checks multiple sources" do
    # Save original state
    original_verbose = @provider.class.verbose_errors_enabled
    original_env = ENV["ACTIVE_AGENT_VERBOSE_ERRORS"]
    original_config = ActiveAgent.configuration.verbose_generation_errors if defined?(ActiveAgent)
    
    begin
      # Reset all sources
      @provider.class.verbose_errors_enabled = false
      @provider.config = {}
      ENV.delete("ACTIVE_AGENT_VERBOSE_ERRORS")
      ActiveAgent.configuration.verbose_generation_errors = false if defined?(ActiveAgent)
      
      # Default is false
      assert_not @provider.send(:verbose_errors?)
      
      # Check instance config (highest priority)
      @provider.config = { "verbose_errors" => true }
      assert @provider.send(:verbose_errors?)
      @provider.config = {}
      
      # Check class attribute
      @provider.class.verbose_errors_enabled = true
      assert @provider.send(:verbose_errors?)
      @provider.class.verbose_errors_enabled = false
      
      # Check ActiveAgent configuration
      if defined?(ActiveAgent)
        ActiveAgent.configuration.verbose_generation_errors = true
        assert @provider.send(:verbose_errors?)
        ActiveAgent.configuration.verbose_generation_errors = false
      end
      
      # Check environment variable (lowest priority)
      ENV["ACTIVE_AGENT_VERBOSE_ERRORS"] = "true"
      assert @provider.send(:verbose_errors?)
    ensure
      # Always restore original state
      if original_env
        ENV["ACTIVE_AGENT_VERBOSE_ERRORS"] = original_env
      else
        ENV.delete("ACTIVE_AGENT_VERBOSE_ERRORS")
      end
      @provider.class.verbose_errors_enabled = original_verbose
      ActiveAgent.configuration.verbose_generation_errors = original_config if defined?(ActiveAgent) && original_config
    end
  end
  
  test "retry_on class method configures retry behavior" do
    class ConfiguredProvider < TestProvider
      retry_on RetryableError, TestError, max_attempts: 5
    end
    
    provider = ConfiguredProvider.new
    assert_equal [RetryableError, TestError], provider.class.retry_on_errors
    assert_equal 5, provider.class.max_retries
  end
  
  test "enable_verbose_errors! class method" do
    class VerboseProvider < TestProvider
      enable_verbose_errors!
    end
    
    provider = VerboseProvider.new
    assert provider.class.verbose_errors_enabled
  end
  
  test "log_retry logs retry attempts" do
    # Test with a simple logger that captures the message
    logged_message = nil
    logger = Object.new
    logger.define_singleton_method(:info) do |msg|
      logged_message = msg
    end
    
    @provider.class.max_retries = 3
    @provider.config = { "logger" => logger }
    @provider.send(:log_retry, RetryableError.new, 1)
    
    assert_match(/Retry attempt 1\/3/, logged_message)
    assert_match(/RetryableError/, logged_message)
  end
  
  test "log_error_details logs detailed error information" do
    # Test with a simple logger that captures messages
    error_message = nil
    debug_message = nil
    logger = Object.new
    logger.define_singleton_method(:error) do |msg|
      error_message = msg
    end
    logger.define_singleton_method(:respond_to?) do |method|
      method == :debug
    end
    logger.define_singleton_method(:debug) do |msg|
      debug_message = msg
    end
    
    @provider.config = { "logger" => logger }
    error = TestError.new("Test error")
    error.set_backtrace(["line1", "line2"])
    
    @provider.send(:log_error_details, error)
    
    assert_match(/Error/, error_message)
    assert_match(/TestError/, error_message)
    assert_match(/Test error/, error_message)
    assert_match(/Backtrace/, debug_message) if debug_message
  end
  
  test "no retry when retry_on_errors is empty" do
    @provider.class.retry_on_errors = []
    @provider.class.max_retries = 3
    
    assert_raises(ActiveAgent::GenerationProvider::Base::GenerationProviderError) do
      @provider.with_error_handling do
        @provider.operation_that_fails
      end
    end
    
    assert_equal 1, @provider.call_count # No retries
  end
  
  test "sleep is called with proper delay on retry" do
    @provider.class.retry_on_errors = [RetryableError]
    @provider.class.max_retries = 1
    
    # Mock sleep to avoid actual delay in tests
    @provider.define_singleton_method(:sleep) do |duration|
      @sleep_called_with = duration
    end
    
    @provider.with_error_handling do
      @provider.operation_that_succeeds_on_retry
    end
    
    assert_equal 1, @provider.instance_variable_get(:@sleep_called_with)
  end
  
  test "find_logger tries multiple sources" do
    # Test with config logger
    config_logger = Object.new
    @provider.config = { "logger" => config_logger }
    assert_equal config_logger, @provider.send(:find_logger)
    
    # Test with no config logger - should find ActiveAgent::Base.logger or Rails.logger
    @provider.config = {}
    logger = @provider.send(:find_logger)
    # It should find some logger (ActiveAgent::Base.logger in test environment)
    assert_not_nil logger if defined?(ActiveAgent::Base)
  end
  
  test "handle_generation_error wraps and logs error" do
    @provider.class.verbose_errors_enabled = true
    logged = false
    
    logger = Object.new
    logger.define_singleton_method(:error) { |_| logged = true }
    logger.define_singleton_method(:respond_to?) { |m| m == :debug }
    logger.define_singleton_method(:debug) { |_| }
    
    @provider.config = { "logger" => logger }
    
    error = TestError.new("Original error")
    assert_raises(ActiveAgent::GenerationProvider::Base::GenerationProviderError) do
      @provider.send(:handle_generation_error, error)
    end
    
    assert logged
  end
  
  test "instrument_error sends notifications if available" do
    # This test would require mocking ActiveSupport::Notifications
    # For now, just ensure the method doesn't error
    error = TestError.new("Test")
    wrapped = ActiveAgent::GenerationProvider::Base::GenerationProviderError.new("Wrapped")
    
    assert_nothing_raised do
      @provider.send(:instrument_error, error, wrapped)
    end
  end
end