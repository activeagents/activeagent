# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Assistant message input
            class AssistantMessage < Base
              attribute :role, :string, as: "assistant"
            end
          end
        end
      end
    end
  end
end
