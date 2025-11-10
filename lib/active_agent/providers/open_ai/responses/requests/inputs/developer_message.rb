# frozen_string_literal: true

require_relative "input_message"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Developer message input (higher priority than system)
            class DeveloperMessage < InputMessage
              attribute :role, :string, as: "developer"
            end
          end
        end
      end
    end
  end
end
