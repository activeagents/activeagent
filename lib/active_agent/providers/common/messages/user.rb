# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Common
      module Messages
        # User message - messages sent by the user
        class User < Base
          attribute :role, :string, as: "user"
          attribute :content, :string # Text content
          attribute :name, :string # Optional name for the user

          validates :content, presence: true
        end
      end
    end
  end
end
