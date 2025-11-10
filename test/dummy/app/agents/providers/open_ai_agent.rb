# frozen_string_literal: true

module Providers
  # Example agent using OpenAI's GPT models.
  #
  # Demonstrates basic prompt generation with the OpenAI provider.
  # Configured to use GPT-4o-mini with default instructions.
  #
  # @example Basic usage
  #   response = Providers::OpenAIAgent.ask(message: "Hello").generate_now
  #   response.message.content  #=> "Hi! How can I help you today?"
  # region agent
  class OpenAIAgent < ApplicationAgent
    generate_with :open_ai, model: "gpt-4o-mini"

    # @return [ActiveAgent::Generation]
    def ask
      prompt(message: params[:message])
    end
  end
  # endregion agent
end
