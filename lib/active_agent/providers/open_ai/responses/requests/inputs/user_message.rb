# frozen_string_literal: true

require_relative "input_message"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # User message input
            class UserMessage < InputMessage
              attribute :role, :string, as: "user"
            end
          end
        end
      end
    end
  end
end
