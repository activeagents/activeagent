# test/docs/framework_examples_test.rb
require "test_helper"

class FrameworkExamplesTest < ActiveSupport::TestCase
  # Nested test case for quick example to isolate SupportAgent class
  class QuickExampleTest < ActiveSupport::TestCase
    # region quick_example_support_agent
    class SupportAgent < ApplicationAgent
      generate_with :openai, model: "gpt-4o-mini"

      # @return [ActiveAgent::Generation]
      def help
        prompt(params[:question])
      end
    end
    # endregion quick_example_support_agent

    test "quick example support agent usage" do
      VCR.use_cassette("docs/framework_examples/quick_example_usage") do
        # region quick_example_support_agent_usage
        response = SupportAgent.with(question: "How do I reset my password?").help.generate_now
        # response.message.content  #=> "To reset your password..."
        # endregion quick_example_support_agent_usage

        # Smoke test: verify response structure
        assert response.is_a?(ActiveAgent::Providers::Common::Responses::Prompt)
        assert response.message.present?
        assert_includes response.message.content.downcase, "password"

        doc_example_output(response)
      end
    end
  end

  # Nested test case for invocation patterns to isolate Agent class
  class InvocationPatternsTest < ActiveSupport::TestCase
    test "invocation patterns" do
      # Define a simple Agent for the examples
      class Agent < ApplicationAgent
        generate_with :openai, model: "gpt-4o-mini"

        def greet(name = nil)
          prompt(message: "Hello #{name || params[:name]}")
        end
      end

      VCR.use_cassette("docs/framework_examples/invocation_patterns") do
        response =
        # region invocation_pattern_direct
        # Direct - no action method needed
        Agent.prompt(message: "Hello").generate_now
        # endregion invocation_pattern_direct

        # Smoke test for direct invocation
        assert response.is_a?(ActiveAgent::Providers::Common::Responses::Prompt)
        assert response.message.present?

        # region invocation_pattern_parameterized
        # Parameterized - passes params to action
        Agent.with(name: "Alice").greet.generate_now
        # endregion invocation_pattern_parameterized

        # region invocation_pattern_action_based
        # Action-based - traditional positional arguments
        Agent.greet("Alice").generate_now
        # endregion invocation_pattern_action_based
      end

      # Smoke test: verify Agent supports these invocation patterns
      assert Agent.respond_to?(:prompt)
      assert Agent.respond_to?(:with)
      assert Agent.new.respond_to?(:greet)
    end
  end
end
