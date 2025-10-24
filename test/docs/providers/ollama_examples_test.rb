# frozen_string_literal: true

require "test_helper"

class Providers::OllamaProviderTest < ActiveSupport::TestCase
  # region ollama_basic_example
  test "basic generation with Ollama" do
    VCR.use_cassette("providers/ollama_basic_generation") do
      response = Providers::OllamaAgent.with(
        message: "What is a design pattern?"
      ).ask.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
      assert response.message.content.length > 0
    end
  end
  # endregion ollama_basic_example

  # region ollama_configuration_example
  test "shows Ollama configuration" do
    VCR.use_cassette("providers/ollama_configuration") do
      # The agent is configured in test/dummy/app/agents/providers/ollama_agent.rb
      # with model: "deepseek-r1:latest"
      response = Providers::OllamaAgent.with(
        message: "Explain the singleton pattern in one sentence"
      ).ask.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
    end
  end
  # endregion ollama_configuration_example

  # region ollama_local_inference
  test "runs local inference" do
    VCR.use_cassette("providers/ollama_local_inference") do
      # Ollama runs locally without external API calls
      response = Providers::OllamaAgent.with(
        message: "What is the SOLID principle?"
      ).ask.generate_now

      doc_example_output(response)

      assert response.success?
      # Local inference - data stays on your machine
      assert_not_nil response.message.content
    end
  end
  # endregion ollama_local_inference

  # region ollama_instructions
  test "follows system instructions" do
    VCR.use_cassette("providers/ollama_instructions") do
      # Agent is configured with: "You are a helpful AI assistant."
      response = Providers::OllamaAgent.with(
        message: "How can you assist me?"
      ).ask.generate_now

      doc_example_output(response)

      assert response.success?
      assert_not_nil response.message.content
    end
  end
  # endregion ollama_instructions

  # region ollama_response_format
  test "returns standard response format" do
    VCR.use_cassette("providers/ollama_response_format") do
      response = Providers::OllamaAgent.with(
        message: "What is 3+4?"
      ).ask.generate_now

      doc_example_output(response)

      assert_equal "assistant", response.message.role
      assert_not_nil response.message.content
    end
  end
  # endregion ollama_response_format
end
