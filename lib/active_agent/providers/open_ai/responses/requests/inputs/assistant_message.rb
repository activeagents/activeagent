# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Assistant message input for OpenAI Responses API.
            #
            # Represents an assistant message in the conversation history.
            class AssistantMessage < Base
              attribute :role, :string, as: "assistant"

              drop_attributes :id, :type, :status
            end
          end
        end
      end
    end
  end
end
