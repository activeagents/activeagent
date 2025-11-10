# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Base class for assistant message outputs
            class OutputMessage < Base
              attribute :id, :string
              attribute :status, :string
              attribute :type, :string, default: "message" # Optional

              validates :role, inclusion: {
                in: %w[assistant],
                allow_nil: false
              }

              validates :status, inclusion: {
                in: %w[in_progress completed incomplete],
                allow_nil: false
              }

              validates :id, presence: true
              validates :content, presence: true
            end
          end
        end
      end
    end
  end
end
