# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Common
      module Messages
        # Assistant message - messages sent by the AI assistant
        class Assistant < Base
          attribute :role, :string, as: "assistant"
          attribute :content, :string # Text content
          attribute :name, :string # Optional name for the assistant

          validates :content, presence: true
        end
      end
    end
  end
end
