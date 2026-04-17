# frozen_string_literal: true

module Providers
  # Example agent using Anthropic models via AWS Bedrock.
  #
  # Demonstrates basic prompt generation with the Bedrock provider.
  # Configured to use Claude Sonnet via cross-region inference.
  #
  # @example Basic usage
  #   response = Providers::BedrockAgent.ask(message: "Hello").generate_now
  #   response.message.content  #=> "Hi! How can I help you today?"
  # region agent
  class BedrockAgent < ApplicationAgent
    generate_with :bedrock, model: "eu.anthropic.claude-sonnet-4-5-20250929-v1:0"

    # @return [ActiveAgent::Generation]
    def ask
      prompt(message: params[:message])
    end
  end
  # endregion agent
end
