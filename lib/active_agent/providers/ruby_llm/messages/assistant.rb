# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module RubyLLM
      module Messages
        # Assistant message for RubyLLM provider.
        #
        # Drops extra fields that are part of the API response but not
        # part of the message structure.
        class Assistant < Base
          attribute :role, :string, as: "assistant"
          attribute :content
          attribute :tool_calls

          validates :content, presence: true, unless: :tool_calls

          # Drop API response fields that aren't part of the message
          drop_attributes :usage, :id, :model, :stop_reason, :stop_sequence, :type,
                          :input_tokens, :output_tokens
        end
      end
    end
  end
end
