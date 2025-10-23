# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module Common
      module Responses
        class Format < Common::BaseModel
          # Type of response format (text, json_object)
          attribute :type, :string, default: "text"

          validates :type, inclusion: { in: %w[text json_object] }, allow_nil: true
        end
      end
    end
  end
end
