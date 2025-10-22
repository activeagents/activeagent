# frozen_string_literal: true

# Example agent using Anthropic's Claude models.
#
# Demonstrates basic prompt generation with the Anthropic provider.
# Configured to use Claude Sonnet 4.5 with default instructions.
#
# @example Basic usage
#   response = Providers::AnthropicAgent.ask(message: "Hello").generate_now
#   response.message.content  #=> "Hi! How can I help you today?"
class Providers::AnthropicAgent < ApplicationAgent
  generate_with :anthropic,
                model: "claude-sonnet-4-5-20250929",
                instructions: "You are a helpful AI assistant."

  # Generates a response to the provided message.
  #
  # @return [ActiveAgent::Generation]
  def ask
    prompt(message: params[:message])
  end
end
