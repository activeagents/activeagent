# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          # Tool choice configuration
          class ToolChoice < Common::BaseModel
            # Can be string ("none", "auto", "required") or object
            attribute :mode, :string
            attribute :type, :string
            attribute :function # Hash with name
            attribute :custom # Hash with name
            attribute :allowed_tools # Hash with mode and tools array

            validates :mode, inclusion: { in: %w[none auto required] }, allow_nil: true
            validates :type, inclusion: { in: %w[function custom allowed_tools] }, allow_nil: true
          end
        end
      end
    end
  end
end
