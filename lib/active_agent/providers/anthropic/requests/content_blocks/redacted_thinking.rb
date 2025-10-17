# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module ContentBlocks
          # Redacted thinking content block
          class RedactedThinking < Base
            attribute :type, :string, as: "redacted_thinking"
            attribute :data, :string

            validates :data, presence: true
          end
        end
      end
    end
  end
end
