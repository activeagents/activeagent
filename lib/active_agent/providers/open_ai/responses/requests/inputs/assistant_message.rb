# frozen_string_literal: true

require_relative "output_message"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Assistant message output for OpenAI Responses API.
            #
            # Represents an assistant message in the conversation history.
            class AssistantMessage < OutputMessage
              attribute :role, :string, as: "assistant"
            end
          end
        end
      end
    end
  end
end
