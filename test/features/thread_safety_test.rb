# frozen_string_literal: true

require "test_helper"

# Tests to verify thread safety of the ActiveAgent framework.
#
# These tests address the concerns raised in GitHub issue #273 where
# the old code had a race condition with shared provider instances.
#
# The refactored code should be thread-safe because:
# 1. Each generation creates a new provider instance (not shared)
# 2. No class-level mutable state that could be corrupted
# 3. Each provider instance has its own context and message stack
#
# Reference: https://github.com/activeagents/activeagent/issues/273
class ThreadSafetyTest < ActiveSupport::TestCase
  # Test agent using Mock provider for fast, deterministic tests
  class TestAgent < ActiveAgent::Base
    generate_with :mock

    def ask
      prompt(message: params[:message])
    end
  end

  # Agent with streaming support
  class StreamingAgent < ActiveAgent::Base
    generate_with :mock

    attr_reader :stream_chunks

    def initialize
      super
      @stream_chunks = []
    end

    on_stream do |chunk|
      @stream_chunks << chunk.delta
    end

    def ask
      prompt(message: params[:message], stream: true)
    end
  end

  # Agent with tool support
  class ToolAgent < ActiveAgent::Base
    generate_with :mock

    def ask
      prompt(
        message: params[:message],
        tools: [ {
          type: "function",
          name: "get_data",
          description: "Gets data for a location",
          parameters: {
            type: "object",
            properties: {
              location: { type: "string", description: "The location" }
            },
            required: [ "location" ]
          }
        } ]
      )
    end

    private

    def get_data(location:)
      "Data for #{location}"
    end
  end

  setup do
    Thread.abort_on_exception = true
  end

  teardown do
    Thread.abort_on_exception = false
  end

  private

  # Helper to run concurrent operations and verify uniqueness
  def run_concurrent(num_threads:, &block)
    results = Concurrent::Array.new
    threads = num_threads.times.map { |i| Thread.new { results << block.call(i) } }
    threads.each(&:join)
    results
  end

  def assert_unique_responses(results, message = "All responses should be unique")
    responses = results.map { |r| r[:response] }
    assert responses.all?(&:present?), "All threads should receive responses"
    assert_equal results.size, responses.uniq.size, message
  end

  public

  test "concurrent generations with different messages do not interfere" do
    # Core issue from #273: multiple threads with different prompts
    # should each get their own correct response back
    results = run_concurrent(num_threads: 20) do |i|
      message = "THREAD_#{i}: What is #{i} plus #{i}?"
      response = TestAgent.with(message: message).ask.generate_now
      { thread_id: i, response: response.message.content }
    end

    assert_unique_responses(results, "Duplicates indicate a race condition")
  end

  test "concurrent parameterized invocations with shared agent class" do
    # Tests the common pattern of using .with() from multiple threads
    results = run_concurrent(num_threads: 15) do |i|
      message = "Request_#{i}_#{SecureRandom.hex(4)}"
      response = TestAgent.with(message: message).ask.generate_now
      { thread_id: i, response: response.message.content }
    end

    assert_unique_responses(results)
  end

  test "concurrent tool calls do not mix up parameters" do
    # Tests tool calling scenario from issue #273
    results = run_concurrent(num_threads: 10) do |i|
      message = "Get data for Location_#{i}"
      response = ToolAgent.with(message: message).ask.generate_now
      { thread_id: i, response: response.message.content }
    end

    assert_unique_responses(results, "Tool responses should not mix between threads")
  end

  test "concurrent streaming generations maintain isolation" do
    results = run_concurrent(num_threads: 5) do |i|
      message = "Stream_#{i}_#{SecureRandom.hex(4)}"
      response = StreamingAgent.with(message: message).ask.generate_now
      { thread_id: i, response: response.message.content }
    end

    assert_unique_responses(results, "Streaming responses should not mix between threads")
  end

  test "high concurrency stress test" do
    errors = Concurrent::Array.new
    results = run_concurrent(num_threads: 50) do |i|
      sleep(rand * 0.01) # Add timing variability
      message = "Concurrent_#{i}_#{SecureRandom.uuid}"
      response = TestAgent.with(message: message).ask.generate_now
      { thread_id: i, response: response.message.content }
    rescue => e
      errors << { thread_id: i, error: e }
      nil
    end.compact

    assert errors.empty?, "No threads should error: #{errors.inspect}"
    assert_unique_responses(results, "Responses should be unique under high concurrency")
  end

  test "exception in one thread does not affect others" do
    Thread.abort_on_exception = false

    failing_agent_class = Class.new(TestAgent) do
      def ask
        raise "Intentional error" if params[:message].include?("FAIL")
        super
      end
    end

    results = run_concurrent(num_threads: 10) do |i|
      message = i == 5 ? "FAIL_#{i}" : "Success_#{i}"
      response = failing_agent_class.with(message: message).ask.generate_now
      { thread_id: i, success: true, response: response.message.content }
    rescue => e
      { thread_id: i, success: false, error: e.message }
    end

    successful = results.select { |r| r[:success] }
    failed = results.reject { |r| r[:success] }

    assert_equal 9, successful.size, "9 threads should succeed"
    assert_equal 1, failed.size, "1 thread should fail"
    assert_equal 5, failed.first[:thread_id]
    assert_unique_responses(successful)
  ensure
    Thread.abort_on_exception = true
  end
end
