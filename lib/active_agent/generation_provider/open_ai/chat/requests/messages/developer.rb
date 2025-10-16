# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module GenerationProvider
    module OpenAI
      module Chat
        module Requests
          module Messages
            # Developer message - instructions that the model should follow (o1 models and newer)
            class Developer < Base
              attribute :role, :string, as: "developer"
              attribute :content # String or array of content parts

              validates :content, presence: true
            end
          end
        end
      end
    end
  end
end
