# frozen_string_literal: true

require_relative "../../../../common/_base_model"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Messages
            # Base class for all OpenAI message types.
            #
            # Provides common message structure and conversion utilities for
            # OpenAI's message format, including role mapping and content extraction.
            class Base < Common::BaseModel
              attribute :role, :string

              validates :role, presence: true

              # Converts to common format.
              #
              # @return [Hash] message in canonical format
              def to_common
                {
                  role: map_role_to_common,
                  content: extract_text_content,
                  name: respond_to?(:name) ? name : nil,
                  tool_call_id: respond_to?(:tool_call_id) ? tool_call_id : nil
                }.compact
              end

              private

              # Maps OpenAI roles to canonical roles.
              #
              # @return [String] canonical role name
              def map_role_to_common
                case role
                when "developer", "system"
                  "system"
                when "user"
                  "user"
                when "assistant"
                  "assistant"
                when "tool", "function"
                  "tool"
                else
                  role
                end
              end

              # Extracts text content from OpenAI's content structure.
              #
              # @return [String, nil] extracted text content
              def extract_text_content
                return nil unless respond_to?(:content)

                case content
                when String
                  content
                when Array
                  # Join all text parts
                  content.select { |part| part.is_a?(Hash) && part["type"] == "text" }
                         .map { |part| part["text"] }
                         .join("\n")
                when nil
                  nil
                else
                  content.to_s
                end
              end
            end
          end
        end
      end
    end
  end
end
