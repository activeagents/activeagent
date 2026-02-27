# frozen_string_literal: true

require "test_helper"

class GenerationJobTest < ActiveSupport::TestCase
  class TestJobError < StandardError; end

  class FailingAgent < ApplicationAgent
    class << self
      attr_accessor :exception_handled
    end

    def self.handle_exception(exception)
      self.exception_handled = exception
      super
    end

    def failing_action
      raise TestJobError, "Job failed"
    end
  end

  setup do
    FailingAgent.exception_handled = nil
  end

  test "handle_exception_with_agent_class calls agent class handle_exception" do
    job = ActiveAgent::GenerationJob.new
    job.arguments = [ "GenerationJobTest::FailingAgent", "failing_action", "prompt_now", { args: [] } ]

    exception = TestJobError.new("Test error")

    # The job should re-raise after the agent logs it
    error = assert_raises(TestJobError) do
      job.send(:handle_exception_with_agent_class, exception)
    end

    assert_same exception, error
    assert_same exception, FailingAgent.exception_handled
  end

  test "handle_exception_with_agent_class re-raises when no agent class" do
    job = ActiveAgent::GenerationJob.new
    job.arguments = []

    exception = TestJobError.new("No agent class")

    error = assert_raises(TestJobError) do
      job.send(:handle_exception_with_agent_class, exception)
    end

    assert_same exception, error
  end
end
