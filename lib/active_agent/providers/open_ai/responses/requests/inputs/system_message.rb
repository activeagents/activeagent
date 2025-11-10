# frozen_string_literal: true

require_relative "input_message"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # System message input
            class SystemMessage < InputMessage
              attribute :role, :string, as: "system"
            end
          end
        end
      end
    end
  end
end
