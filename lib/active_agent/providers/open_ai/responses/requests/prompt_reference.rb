# frozen_string_literal: true

require_relative "../../../common/_base_model"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          class PromptReference < Common::BaseModel
            # Prompt ID or name
            attribute :id, :string

            # Variables for the prompt template
            attribute :variables # Hash of variables

            validates :id, presence: true
          end
        end
      end
    end
  end
end
