# frozen_string_literal: true

module Providers
  # Example agent using OpenRouter's model routing service.
  #
  # Demonstrates basic prompt generation with the OpenRouter provider.
  # Configured to use Qwen 3 30B (free tier) with default instructions.
  #
  # @example Basic usage
  #   response = Providers::OpenRouterAgent.ask(message: "Hello").generate_now
  #   response.message.content  #=> "Hi! How can I help you today?"
  # region agent
  class OpenRouterAgent < ApplicationAgent
    generate_with :open_router, model: "openrouter/auto"

    # @return [ActiveAgent::Generation]
    def ask
      prompt(message: params[:message])
    end
  end
  # endregion agent
end
