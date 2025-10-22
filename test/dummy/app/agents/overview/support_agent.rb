# frozen_string_literal: true

module Overview
  # Example agent for the overview documentation.
  #
  # Demonstrates the basic Rails MVC pattern applied to AI agents.
  # Shows how agents act as controllers with actions that render views.
  #
  # @example Basic usage
  #   response = SupportAgent.with(question: "How do I reset my password?").help.generate_now
  #   response.message.content  #=> "To reset your password..."
  # region overview_support_agent
  class SupportAgent < ApplicationAgent
    generate_with :openai, model: "gpt-4o-mini"

    # @return [ActiveAgent::Generation]
    def help
      prompt
    end
  end
  # endregion overview_support_agent
end
