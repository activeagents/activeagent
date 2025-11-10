# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module Common
      module Responses
        class Format < Common::BaseModel
          # Type of response format (text, json_object, json_schema)
          attribute :type, :string, default: "text"
          attribute :name, :string
          attribute :schema

          validates :type, inclusion: { in: %w[text json_object json_object] }, allow_nil: true

          # OpenAI's Responses => Common Format
          def format=(value)
            self.type = value[:type]
          end

          # OpenAI's Chat => Common Format
          def json_schema=(value)
            self.name   = value[:name]   if value[:name]
            self.schema = value[:schema] if value[:schema]
          end
        end
      end
    end
  end
end
