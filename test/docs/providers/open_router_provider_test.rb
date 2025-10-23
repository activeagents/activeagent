# frozen_string_literal: true

require "test_helper"

class Providers::OpenRouterProviderTest < ActiveSupport::TestCase
  # region openrouter_basic_example
  test "basic generation with OpenRouter" do
    VCR.use_cassette("providers/openrouter_basic_generation") do
      response = Providers::OpenRouterAgent.with(
        message: "What is functional programming?"
      ).ask.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
      assert response.message.content.length > 0
    end
  end
  # endregion openrouter_basic_example

  # region openrouter_configuration_example
  test "shows OpenRouter configuration" do
    VCR.use_cassette("providers/openrouter_configuration") do
      # The agent is configured in test/dummy/app/agents/providers/open_router_agent.rb
      # with model: "qwen/qwen3-30b-a3b:free"
      response = Providers::OpenRouterAgent.with(
        message: "Explain monads in one sentence"
      ).ask.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
    end
  end
  # endregion openrouter_configuration_example

  # region openrouter_model_routing
  test "uses OpenRouter's model routing" do
    VCR.use_cassette("providers/openrouter_model_routing") do
      # OpenRouter provides access to multiple providers
      response = Providers::OpenRouterAgent.with(
        message: "What is the difference between async and sync?"
      ).ask.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
    end
  end
  # endregion openrouter_model_routing

  # region openrouter_instructions
  test "follows system instructions" do
    VCR.use_cassette("providers/openrouter_instructions") do
      # Agent is configured with: "You are a helpful AI assistant."
      response = Providers::OpenRouterAgent.with(
        message: "What is your purpose?"
      ).ask.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
    end
  end
  # endregion openrouter_instructions

  # region openrouter_response_format
  test "returns standard response format" do
    VCR.use_cassette("providers/openrouter_response_format") do
      response = Providers::OpenRouterAgent.with(
        message: "What is 10-3?"
      ).ask.generate_now

      doc_example_output(response)

      assert_equal "assistant", response.message.role
      assert_not_nil response.message.content
    end
  end
  # endregion openrouter_response_format
end
