# frozen_string_literal: true

require "test_helper"

class ResponseDelegationTest < ActiveSupport::TestCase
  class TestAgent < ActiveAgent::Base
    def test_action
      prompt(message: "Test message")
    end

    after_generation :check_response_access

    private

    def check_response_access
      # This should work now with delegation
      assert response.present?
      assert_equal response, generation_provider.response
    end
  end

  test "agent delegates response to generation_provider" do
    agent = TestAgent.new

    # Create a simple test provider that tracks response
    test_provider = Class.new do
      attr_accessor :response

      def generate(prompt)
        @response = ActiveAgent::GenerationProvider::Response.new(
          prompt: prompt,
          message: ActiveAgent::ActionPrompt::Message.new(content: "Test response", role: :assistant)
        )
      end
    end.new

    # Replace the generation_provider
    agent.stub :generation_provider, test_provider do
      # No response before generation
      assert_nil agent.response

      # Simulate generation
      agent.instance_variable_set(:@context, ActiveAgent::ActionPrompt::Prompt.new)
      agent.send(:perform_generation)

      # Now response should be delegated from generation_provider
      assert agent.response.present?
      assert_equal "Test response", agent.response.message.content
      assert_equal test_provider.response, agent.response
    end
  end

  test "response delegation handles nil generation_provider gracefully" do
    agent = TestAgent.new
    agent.stub :generation_provider, nil do
      assert_nil agent.response
    end
  end
end
