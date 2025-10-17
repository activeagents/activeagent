# frozen_string_literal: true

require_relative "../../../common/_base_model"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module Messages
          # Base class for Anthropic messages
          class Base < Common::BaseModel
            attribute :role, :string
            attribute :content, Types::ContentType.new # Can be string or array of content blocks

            validates :role, presence: true, inclusion: { in: %w[user assistant] }

            def to_hash_compressed
              super.tap do |hash|
                # If there is a only a single text we can compress down to a string
                if content.is_a?(Array) && content.one? && content.first.type == "text"
                  hash[:content] = content.first.text
                end
              end
            end
          end
        end
      end
    end
  end
end
