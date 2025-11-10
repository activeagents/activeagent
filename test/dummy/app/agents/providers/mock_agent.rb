# frozen_string_literal: true

module Providers
  # Example agent using the mock provider for testing.
  #
  # Demonstrates basic prompt generation with the mock provider.
  # Useful for testing without making actual API calls.
  #
  # @example Basic usage
  #   response = Providers::MockAgent.ask(message: "Hello").generate_now
  #   response.message.content  #=> "Mock response"
  # region agent
  class MockAgent < ApplicationAgent
    generate_with :mock

    # @return [ActiveAgent::Generation]
    def ask
      prompt(message: params[:message])
    end
  end
  # endregion agent
end
