# frozen_string_literal: true

# Example agent using OpenRouter's model routing service.
#
# Demonstrates basic prompt generation with the OpenRouter provider.
# Configured to use Qwen 3 30B (free tier) with default instructions.
#
# @example Basic usage
#   response = Providers::OpenRouterAgent.ask(message: "Hello").generate_now
#   response.message.content  #=> "Hi! How can I help you today?"
class Providers::OpenRouterAgent < ApplicationAgent
  generate_with :open_router,
                model: "qwen/qwen3-30b-a3b:free",
                instructions: "You are a helpful AI assistant."

  # Generates a response to the provided message.
  #
  # @return [ActiveAgent::Generation]
  def ask
    prompt(message: params[:message])
  end
end
