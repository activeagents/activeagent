# frozen_string_literal: true

require_relative "../../../common/_base_model"

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

            def to_hash_compressed
              # If it's just a mode string, return the string
              return mode if mode.present? && type.blank? && function.blank? && custom.blank? && allowed_tools.blank?

              super
            end
          end
        end
      end
    end
  end
end
