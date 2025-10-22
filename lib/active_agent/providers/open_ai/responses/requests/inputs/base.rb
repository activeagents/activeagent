# frozen_string_literal: true

require "active_agent/providers/common/model"
require_relative "content/_types"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Base class for input items in Responses API
            class Base < Common::BaseModel
              attribute :role, :string
              attribute :content, Content::ContentsType.new

              validates :role, inclusion: {
                in: %w[system user assistant developer tool],
                allow_nil: true
              }

              # Define content setter methods for different content types
              %i[text image document].each do |content_type|
                define_method(:"#{content_type}=") do |value|
                  self.content ||= []
                  self.content += [ { content_type => value } ]
                end
              end

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
                  # For Responses API, content is an array of content objects (InputText, etc.)
                  content.select { |part| part.respond_to?(:text) }
                         .map(&:text)
                         .compact
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
