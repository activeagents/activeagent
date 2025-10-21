# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Reasoning item for chain of thought from reasoning models
            class Reasoning < Base
              attribute :type, :string, as: "reasoning"
              attribute :id, :string
              attribute :encrypted_content, :string
              attribute :summary # Always an array of summary content
              attribute :content # Always an array of reasoning text content
              attribute :status, :string

              validates :type, inclusion: { in: %w[reasoning], allow_nil: false }
              validates :id, presence: true
              validates :summary, presence: true
              validates :status, inclusion: {
                in: %w[in_progress completed incomplete],
                allow_nil: true
              }
            end
          end
        end
      end
    end
  end
end
