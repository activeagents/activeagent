# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Common
      module Messages
        # Represents a message sent by the user in a conversation
        class User < Base
          attribute :role, :string, as: "user"
          attribute :content, :string
          attribute :name, :string

          validates :content, presence: true
        end
      end
    end
  end
end
