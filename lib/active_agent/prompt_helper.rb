# frozen_string_literal: true

module ActiveAgent
  # = Active Agent's Action Prompt \PromptHelper
  #
  # Provides helper methods for ActiveAgent::Base that can be used for easily
  # formatting prompts, accessing agent or prompt instances.
  module PromptHelper
    # Access the agent instance.
    def agent
      @_controller
    end

    # Access the prompt instance.
    def context
      @_context
    end
  end
end
