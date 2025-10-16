# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Messages
            # System message - instructions that the model should follow (older models)
            class System < Base
              attribute :role, :string, as: "system"
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
