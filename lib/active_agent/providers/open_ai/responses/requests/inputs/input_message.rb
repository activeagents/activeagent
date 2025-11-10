# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Base class for user, system, and developer message inputs
            class InputMessage < Base
              attribute :status, :string
              attribute :type, :string, default: "message" # Optional

              validates :role, inclusion: {
                in: %w[user system developer],
                allow_nil: false
              }

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
