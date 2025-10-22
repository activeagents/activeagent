# frozen_string_literal: true

# Example agent using OpenAI's GPT models.
#
# Demonstrates basic prompt generation with the OpenAI provider.
# Configured to use GPT-4o-mini with default instructions.
#
# @example Basic usage
#   response = Providers::OpenAIAgent.ask(message: "Hello").generate_now
#   response.message.content  #=> "Hi! How can I help you today?"
class Providers::OpenAIAgent < ApplicationAgent
  generate_with :openai,
                model: "gpt-4o-mini",
                instructions: "You are a helpful AI assistant."

  # Generates a response to the provided message.
  #
  # @return [ActiveAgent::Generation]
  def ask
    prompt(message: params[:message])
  end
end
