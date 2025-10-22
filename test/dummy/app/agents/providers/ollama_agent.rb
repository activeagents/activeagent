# frozen_string_literal: true

module Providers
  # Example agent using locally-hosted Ollama models.
  #
  # Demonstrates basic prompt generation with the Ollama provider.
  # Configured to use DeepSeek R1 with default instructions.
  #
  # @example Basic usage
  #   response = Providers::OllamaAgent.ask(message: "Hello").generate_now
  #   response.message.content  #=> "Hi! How can I help you today?"
  # region agent
  class OllamaAgent < ApplicationAgent
    generate_with :ollama, model: "deepseek-r1:latest"

    # @return [ActiveAgent::Generation]
    def ask
      prompt(message: params[:message])
    end
  end
  # endregion agent
end
