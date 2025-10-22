require "test_helper"

class ParameterizedAgent < ActiveAgent::Base
  generate_with :openai, model: "gpt-4o-mini", instructions: "You are a helpful assistant."

  def greet_user
    prompt(message: "Hello #{params[:name]}, you are a #{params[:role]}!")
  end

  def custom_context
    prompt(
      message: params[:message],
      options: { temperature: params[:temperature] || 0.7 }
    )
  end

  def with_arguments(topic)
    prompt(message: "Tell me about #{topic}. User: #{params[:user_id]}")
  end
end

class ParameterizedTest < ActiveSupport::TestCase
  test "agent includes parameterized concern" do
    assert ParameterizedAgent.respond_to?(:with)
    assert ParameterizedAgent.respond_to?(:prompt_with)
  end

  test "with returns an Agent proxy" do
    agent_proxy = ParameterizedAgent.with(name: "Alice")
    assert_instance_of ActiveAgent::Parameterized::Agent, agent_proxy
  end

  test "prompt_with is an alias for with" do
    agent_proxy1 = ParameterizedAgent.with(name: "Alice")
    agent_proxy2 = ParameterizedAgent.prompt_with(name: "Alice")

    assert_equal agent_proxy1.class, agent_proxy2.class
  end

  test "agent proxy delegates action methods to Generation" do
    agent_proxy = ParameterizedAgent.with(name: "Alice", role: "developer")
    generation = agent_proxy.greet_user

    assert_instance_of ActiveAgent::Parameterized::Generation, generation
  end

  test "params are accessible in agent actions" do
    agent = ParameterizedAgent.new
    agent.params = { name: "Bob", role: "designer" }
    agent.process(:greet_user)

    assert_equal "Bob", agent.params[:name]
    assert_equal "designer", agent.params[:role]
  end

  test "params default to empty hash" do
    agent = ParameterizedAgent.new
    assert_equal({}, agent.params)
  end

  test "params can be set" do
    agent = ParameterizedAgent.new
    agent.params = { name: "Charlie" }

    assert_equal "Charlie", agent.params[:name]
  end

  test "processed_agent creates new agent instance with params" do
    generation = ParameterizedAgent.with(name: "Charlie", role: "admin").greet_user

    # Generation starts as not processed
    assert_not generation.processed?
  end

  test "empty params work correctly" do
    generation = ParameterizedAgent.with({}).greet_user

    assert_instance_of ActiveAgent::Parameterized::Generation, generation
  end

  private

  def has_openai_credentials?
    ENV["OPENAI_API_KEY"].present?
  end
end
