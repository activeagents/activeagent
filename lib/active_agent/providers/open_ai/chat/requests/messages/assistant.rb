# frozen_string_literal: true

require_relative "base"
require_relative "content/_types"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Messages
            # Assistant message - messages sent by the model
            class Assistant < Base
              attribute :role, :string, as: "assistant"
              attribute :content # String, null, or array of content parts
              attribute :name, :string # Optional name for the participant
              attribute :audio # Audio response from the model
              attribute :refusal, :string # Refusal message if the model refused to respond
              attribute :tool_calls # Array of tool calls the model wants to make
              attribute :function_call # Deprecated: function call (use tool_calls instead)

              # Assistant messages need content, tool_calls, function_call, or refusal
              validate :validate_has_response_content

              drop_attributes :annotations, :index

              alias_attribute :text, :content

              private

              def validate_has_response_content
                if content.nil? && tool_calls.nil? && function_call.nil? && refusal.nil?
                  errors.add(:base, "must have content, tool_calls, function_call, or refusal")
                end
              end
            end
          end
        end
      end
    end
  end
end
