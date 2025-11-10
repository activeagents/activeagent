# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module Mock
      module Messages
        # User message for Mock provider.
        class User < Base
          attribute :role, :string, as: "user"

          validates :content, presence: true
        end
      end
    end
  end
end
