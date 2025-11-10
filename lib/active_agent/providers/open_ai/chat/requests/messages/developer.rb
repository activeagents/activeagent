# frozen_string_literal: true

require_relative "base"
require_relative "content/_types"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Messages
            # Developer message - instructions that the model should follow (o1 models and newer)
            class Developer < Base
              attribute :role, :string, as: "developer"
              attribute :content, Content::ContentsType.new # String or array of content parts
              attribute :name, :string # Optional name for the participant

              validates :content, presence: true
            end
          end
        end
      end
    end
  end
end
