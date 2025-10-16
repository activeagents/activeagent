# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Developer message input (higher priority than system)
            class DeveloperMessage < Base
              attribute :role, :string, as: "developer"
            end
          end
        end
      end
    end
  end
end
