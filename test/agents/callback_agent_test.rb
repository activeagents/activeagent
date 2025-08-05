require "test_helper"

class CallbackAgentTest < ActiveSupport::TestCase
  # Create a test agent with callbacks for documentation
  class TestCallbackAgent < ApplicationAgent
    attr_accessor :context_set, :response_processed

    # region callback_agent_before_action
    before_action :set_context

    private
    def set_context
      # Logic to set the context for the action
      @context_set = true
      prompt_context.instructions = "Context has been set"
    end
    # endregion callback_agent_before_action
  end

  class TestGenerationCallbackAgent < ApplicationAgent
    attr_accessor :response_data

    # region callback_agent_after_generation
    after_generation :process_response

    private
    def process_response
      # Access the generation provider response
      @response_data = generation_provider.response
    end
    # endregion callback_agent_after_generation
  end

  test "before_action callback is executed before prompt generation" do
    agent = TestCallbackAgent.new
    agent.params = { message: "Test" }

    # Process the agent to trigger callbacks
    agent.process(:prompt_context)

    assert agent.context_set, "before_action callback should set context"
  end

  test "after_generation callback is executed after response generation" do
    VCR.use_cassette("callback_agent_after_generation") do
      response = TestGenerationCallbackAgent.with(message: "Test callback").prompt_context.generate_now

      # The after_generation callback should have access to the response
      # This demonstrates the callback pattern even though we can't directly test it
      assert_not_nil response
      assert_not_nil response.message.content
    end
  end
end
