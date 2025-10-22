# frozen_string_literal: true

require "test_helper"

class ProviderExamplesTest < ActiveSupport::TestCase
  # Mock Provider Tests
  test "Mock agent basic generation" do
    # region mock_basic_example
    response = Providers::MockAgent.with(message: "What is ActiveAgent?").ask.generate_now
    # endregion mock_basic_example

    doc_example_output(response)

    assert response.success?
    assert_not_nil response.message.content
    assert response.message.content.length > 0
  end

  # OpenAI Provider Tests
  test "OpenAI agent basic generation" do
    VCR.use_cassette("providers/openai_basic_generation") do
      # region openai_basic_example
      response = Providers::OpenAIAgent.with(message: "What is Ruby on Rails?").ask.generate_now
      # endregion openai_basic_example

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
      assert response.message.content.length > 0
    end
  end

  # Anthropic Provider Tests
  test "Anthropic agent basic generation" do
    VCR.use_cassette("providers/anthropic_basic_generation") do
      # region anthropic_basic_example
      response = Providers::AnthropicAgent.with(message: "What is the Model Context Protocol?").ask.generate_now
      # endregion anthropic_basic_example

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
      assert response.message.content.length > 0
    end
  end

  # Ollama Provider Tests
  test "Ollama agent basic generation" do
    VCR.use_cassette("providers/ollama_basic_generation") do
      # region ollama_basic_example
      response = Providers::OllamaAgent.with(message: "What is a design pattern?").ask.generate_now
      # endregion ollama_basic_example

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
      assert response.message.content.length > 0
    end
  end

  # OpenRouter Provider Tests
  test "OpenRouter agent basic generation" do
    VCR.use_cassette("providers/openrouter_basic_generation") do
      # region openrouter_basic_example
      response = Providers::OpenRouterAgent.with(message: "What is functional programming?").ask.generate_now
      # endregion openrouter_basic_example

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
      assert response.message.content.length > 0
    end
  end
end
