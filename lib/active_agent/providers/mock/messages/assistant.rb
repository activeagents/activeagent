# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Mock
      module Messages
        # Assistant message for Mock provider.
        #
        # Drops extra fields that are part of the API response but not
        # part of the message structure (usage, id, model, stop_reason, type, etc).
        class Assistant < Base
          attribute :role, :string, as: "assistant"
          attribute :content # Can be string or array of content blocks
          attribute :name, :string

          validates :content, presence: true

          # Drop API response fields that aren't part of the message
          drop_attributes :usage, :id, :model, :stop_reason, :stop_sequence, :type
        end
      end
    end
  end
end
