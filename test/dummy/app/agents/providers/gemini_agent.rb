# frozen_string_literal: true

module Providers
  # Example agent using Google's Gemini models.
  #
  # Demonstrates basic prompt generation with the Gemini provider.
  # Configured to use Gemini 2.0 Flash with default instructions.
  #
  # @example Basic usage
  #   response = Providers::GeminiAgent.ask(message: "Hello").generate_now
  #   response.message.content  #=> "Hi! How can I help you today?"
  # region agent
  class GeminiAgent < ApplicationAgent
    generate_with :gemini, model: "gemini-2.0-flash"

    # @return [ActiveAgent::Generation]
    def ask
      prompt(message: params[:message])
    end
  end
  # endregion agent
end
