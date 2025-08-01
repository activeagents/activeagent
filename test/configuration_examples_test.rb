require "test_helper"

class ConfigurationExamplesTest < ActiveSupport::TestCase
  # Test agents for documentation examples
  
  # region application_agent_basic_configuration
  class ExampleApplicationAgent < ActiveAgent::Base
    generate_with :openai, 
      instructions: "You are a helpful assistant.",
      model: "gpt-4o-mini",
      temperature: 0.7
  end
  # endregion application_agent_basic_configuration
  
  # region travel_agent_example
  class TravelAgent < ApplicationAgent
    def search
      # Your search logic here
      prompt
    end

    def book
      # Your booking logic here
      prompt
    end

    def confirm
      # Your confirmation logic here
      prompt
    end
  end
  # endregion travel_agent_example
  
  # region travel_agent_with_views
  class TravelAgentWithViews < ApplicationAgent
    def search
      @results = fetch_travel_options
      @departure = params[:departure]
      @destination = params[:destination]
      prompt
    end
    
    private
    def fetch_travel_options
      # Mock travel options for documentation
      [
        { airline: "United", price: 450, departure: "09:00" },
        { airline: "Delta", price: 425, departure: "14:30" }
      ]
    end
  end
  # endregion travel_agent_with_views
  
  # region parameterized_agent_example
  class ParameterizedAgent < ApplicationAgent
    def analyze
      # Access parameters passed to the agent
      @topic = params[:topic]
      @depth = params[:depth] || "medium"
      prompt
    end
  end
  # endregion parameterized_agent_example
  
  test "application agent is configured correctly" do
    # _generation_provider returns the provider instance, not symbol
    assert ExampleApplicationAgent._generation_provider.is_a?(ActiveAgent::GenerationProvider::OpenAIProvider)
    # The configuration is stored in the provider's config
    provider = ExampleApplicationAgent._generation_provider
    assert_equal "gpt-4o-mini", provider.instance_variable_get(:@model_name)
  end
  
  test "travel agent has required actions" do
    agent = TravelAgent.new
    assert_respond_to agent, :search
    assert_respond_to agent, :book
    assert_respond_to agent, :confirm
  end
  
  test "parameterized agent accesses params" do
    # region parameterized_agent_usage
    agent = ParameterizedAgent.with(topic: "AI Safety", depth: "detailed")
    # Agent is parameterized with topic and depth
    # These params are accessible in the agent's actions
    # endregion parameterized_agent_usage
    
    # The params are stored internally and accessed via params method in actions
    assert_not_nil agent
    # agent.with returns a ParameterizedAgent instance wrapped in a delegator
    assert_respond_to agent, :analyze
  end
end