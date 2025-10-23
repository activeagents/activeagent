# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        # Configures the response format for Anthropic API requests.
        #
        # Anthropic does not natively support response formats. This class emulates
        # the feature using a lead-in assistant message and response parsing.
        class ResponseFormat < Common::BaseModel
          # @return [String] format type: "text" or "json_object"
          attribute :type, :string, default: "text"

          validates :type, inclusion: { in: %w[text json_object] }, allow_nil: true
        end
      end
    end
  end
end
