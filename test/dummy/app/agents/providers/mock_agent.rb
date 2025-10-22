# frozen_string_literal: true

# Example agent using the mock provider for testing.
#
# Demonstrates basic prompt generation with the mock provider.
# Useful for testing without making actual API calls.
#
# @example Basic usage
#   response = Providers::MockAgent.ask(message: "Hello").generate_now
#   response.message.content  #=> "Mock response"
class Providers::MockAgent < ApplicationAgent
  generate_with :mock,
                instructions: "You are a helpful AI assistant."

  # Generates a response to the provided message.
  #
  # @return [ActiveAgent::Generation]
  def ask
    prompt(message: params[:message])
  end
end
