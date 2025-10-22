# frozen_string_literal: true

module Providers
  # Example agent using Anthropic's Claude models.
  #
  # Demonstrates basic prompt generation with the Anthropic provider.
  # Configured to use Claude Sonnet 4.5 with default instructions.
  #
  # @example Basic usage
  #   response = Providers::AnthropicAgent.ask(message: "Hello").generate_now
  #   response.message.content  #=> "Hi! How can I help you today?"
  # region agent
  class AnthropicAgent < ApplicationAgent
    generate_with :anthropic, model: "claude-sonnet-4-5-20250929"

    # @return [ActiveAgent::Generation]
    def ask
      prompt(message: params[:message])
    end
  end
  # endregion agent
end
