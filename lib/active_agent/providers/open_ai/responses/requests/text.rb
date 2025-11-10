# frozen_string_literal: true

require "active_agent/providers/common/model"
require_relative "text/_types"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          class Text < Common::BaseModel
            # Format configuration for text output
            attribute :format, TextFormats::FormatType.new

            # Modalities for output
            attribute :modalities, default: -> { [] } # Array of strings

            # Verbosity setting
            attribute :verbosity, :string

            validates :verbosity, inclusion: { in: %w[concise default verbose] }, allow_nil: true

            # Common Format compatibility - maps format.type to type
            def type
              format&.type
            end

            def type=(value)
              self.format = value
            end

            # For Common Format
            def json_schema=(value)
              self.format = { type: "json_schema", **value }
            end
          end
        end
      end
    end
  end
end
