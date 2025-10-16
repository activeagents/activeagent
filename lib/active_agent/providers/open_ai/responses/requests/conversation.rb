# frozen_string_literal: true

require_relative "../../../common/_base_model"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
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
end
