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

              # Drops id attribute during message reconstruction.
              # @param value [String] id value to ignore
              def id=(value); end

              # Drops type attribute during message reconstruction.
              # @param value [String] type value to ignore
              def type=(value); end

              # Drops status attribute during message reconstruction.
              # @param value [String] status value to ignore
              def status=(value); end
            end
          end
        end
      end
    end
  end
end
