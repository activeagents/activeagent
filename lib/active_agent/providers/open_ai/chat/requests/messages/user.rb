# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Messages
            # User message - messages sent by an end user
            class User < Base
              attribute :role, :string, as: "user"
              attribute :content # String or array of content parts
              attribute :name, :string # Optional name for the participant

              validates :content, presence: true
            end
          end
        end
      end
    end
  end
end
