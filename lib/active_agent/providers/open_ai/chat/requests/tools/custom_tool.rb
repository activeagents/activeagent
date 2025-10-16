# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Chat
        module Requests
          module Tools
            # Custom tool
            class CustomTool < Base
              attribute :type, :string, as: "custom"
              attribute :custom # Hash with name, description, format

              validate :validate_custom_structure

              private

              def validate_custom_structure
                if custom.blank?
                  errors.add(:custom, "must be present")
                  return
                end

                unless custom.is_a?(Hash)
                  errors.add(:custom, "must be a hash")
                  return
                end

                unless custom[:name].present?
                  errors.add(:custom, "must include 'name' field")
                end
              end
            end
          end
        end
      end
    end
  end
end
