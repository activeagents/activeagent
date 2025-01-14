# frozen_string_literal: true

require_relative "test_helper"

require_relative "abstract_unit"
require "active_job"
require_relative "agents/params_agent"
# ActiveAgent.load_configuration(Rails.root + "/lib/active_agent/generation_provider/agents.yml")
class ParameterizedTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class PromptTestJob < ActiveAgent::GenerationJob
  end

  setup do
    @previous_logger = ActiveJob::Base.logger
    ActiveJob::Base.logger = Logger.new(nil)

    @prompt = ParamsAgent.with(instructions: "Welcome to the project!", context: [{content: "Hello, world!", role: "user"}]).welcome
  end

  teardown do
    ActiveJob::Base.logger = @previous_logger
  end

  test "parameterized headers" do
    assert_equal("Welcome to the project!", @prompt.instructions)
    assert_equal([{content: "Hello, world!", role: "user"}], @prompt.context)
    assert_equal("Instructions: Welcome to the project!", @prompt.message.content)
  end

  test "degrade gracefully when .with is not called" do
    @prompt = ParamsAgent.welcome

    assert_nil(@prompt.instructions)
    assert_nil(@prompt.context)
  end

  test "enqueue the prompt with params" do
    args = [
      "ParamsAgent",
      "welcome",
      "generate_now",
      params: {instruction: "Welcome to the project!", context: [{content: "Hello, world!", role: "user"}]},
      args: []
    ]
    assert_performed_with(job: ActiveAgent::GenerationJob, args: args) do
      @prompt.generate_later
    end
  end

  test "respond_to?" do
    agent = ParamsAgent.with(instructions: "Welcome to the project!", context: [{content: "Hello, world!", role: "user"}])

    assert_respond_to agent, :welcome
    assert_not_respond_to agent, :anything

    welcome = agent.method(:welcome)
    assert_equal Method, welcome.class

    assert_raises(NameError) do
      welcome = agent.method(:anything)
    end
  end

  test "should enqueue a parameterized request with the correct generation job" do
    args = [
      "ParamsAgent",
      "welcome",
      "generate_now",
      params: {instructions: "Welcome to the project!", context: [{content: "Hello, world!", role: "user"}]},
      args: []
    ]

    with_generation_job PromptTestJob do
      assert_performed_with(job: PromptTestJob, args: args) do
        @prompt.generate_later
      end
    end
  end

  private

  def with_generation_job(job)
    old_generation_job = ParamsAgent.generation_job
    ParamsAgent.generation_job = job
    yield
  ensure
    ParamsAgent.generation_job = old_generation_job
  end
end
