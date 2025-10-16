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
              attribute :encrypted_content, :string
              attribute :status, :string

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
