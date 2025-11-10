# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Messages
            # Function message - result from a function call (deprecated)
            class Function < Base
              attribute :role, :string, as: "function"
              attribute :content, :string # Result of the function call
              attribute :name, :string # Name of the function that was called

              validates :content, presence: true
              validates :name, presence: true
            end
          end
        end
      end
    end
  end
end
