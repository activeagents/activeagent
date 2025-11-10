# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          # Tool choice configuration for Responses API
          # Controls how the model should select which tool (or tools) to use when generating a response.
          class ToolChoice < Common::BaseModel
            # Can be string ("none", "auto", "required") or object with type and tool details
            attribute :mode, :string
            attribute :type, :string
            attribute :function # Hash with name
            attribute :custom # Hash with name

            validates :mode, inclusion: { in: %w[none auto required] }, allow_nil: true
            validates :type, inclusion: { in: %w[function custom] }, allow_nil: true
          end
        end
      end
    end
  end
end
