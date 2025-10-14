# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    module OpenAI
      module Responses
        class Conversation < Common::BaseModel
          # Conversation ID
          attribute :id, :string

          # Optional: Store conversation items
          attribute :store, :boolean

          validates :id, presence: true, if: -> { store.nil? }
        end
      end
    end
  end
end
