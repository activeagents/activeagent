# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # System message input
            class SystemMessage < Base
              attribute :role, :string, as: "system"
            end
          end
        end
      end
    end
  end
end
