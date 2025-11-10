# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Common
      module Messages
        # System message - provides instructions and context to the AI
        class System < Base
          attribute :role, :string, as: "system"
          attribute :content, :string # Text content
          attribute :name, :string # Optional name for the system message

          validates :content, presence: true
        end
      end
    end
  end
end
