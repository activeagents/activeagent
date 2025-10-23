# frozen_string_literal: true

require "test_helper"

class Providers::OpenAIProviderTest < ActiveSupport::TestCase
  # region openai_basic_example
  test "basic generation with OpenAI GPT" do
    VCR.use_cassette("providers/openai_basic_generation") do
      response = Providers::OpenAIAgent.with(
        message: "What is Ruby on Rails?"
      ).ask.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
      assert response.message.content.length > 0
    end
  end
  # endregion openai_basic_example

  # region openai_configuration_example
  test "shows OpenAI configuration" do
    VCR.use_cassette("providers/openai_configuration") do
      # The agent is configured in test/dummy/app/agents/providers/open_ai_agent.rb
      # with model: "gpt-4o-mini"
      response = Providers::OpenAIAgent.with(
        message: "Explain dependency injection in one sentence"
      ).ask.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
    end
  end
  # endregion openai_configuration_example

  # region openai_chat_interaction
  test "handles chat interactions" do
    VCR.use_cassette("providers/openai_chat_interaction") do
      response = Providers::OpenAIAgent.with(
        message: "Hello! Can you help me understand REST APIs?"
      ).ask.generate_now

      doc_example_output(response)

      assert response.success?
      assert_includes response.message.content.downcase, "api"
    end
  end
  # endregion openai_chat_interaction

  # region openai_instructions
  test "follows system instructions" do
    VCR.use_cassette("providers/openai_instructions") do
      # Agent is configured with: "You are a helpful AI assistant."
      response = Providers::OpenAIAgent.with(
        message: "What kind of assistant are you?"
      ).ask.generate_now

      doc_example_output(response)

      assert response.success?
      assert_includes response.message.content.downcase, "assist"
    end
  end
  # endregion openai_instructions

  # region openai_response_format
  test "returns standard response format" do
    VCR.use_cassette("providers/openai_response_format") do
      response = Providers::OpenAIAgent.with(
        message: "What is 5*7?"
      ).ask.generate_now

      doc_example_output(response)

      assert_equal "assistant", response.message.role
      assert_not_nil response.message.content
      assert_not_nil response.raw_response
    end
  end
  # endregion openai_response_format
end
