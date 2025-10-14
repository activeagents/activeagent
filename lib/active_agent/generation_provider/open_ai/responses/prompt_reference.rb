# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    module OpenAI
      module Responses
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
