# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module ContentBlocks
          # Thinking content block
          class Thinking < Base
            attribute :type, :string, as: "thinking"
            attribute :thinking, :string
            attribute :signature, :string

            validates :thinking, presence: true
            validates :signature, presence: true
          end
        end
      end
    end
  end
end
