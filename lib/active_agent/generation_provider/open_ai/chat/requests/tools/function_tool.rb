# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module GenerationProvider
    module OpenAI
      module Chat
        module Requests
          module Tools
            # Function tool
            class FunctionTool < Base
              attribute :type, :string, as: "function"
              attribute :function # Hash with name, description, parameters, strict

              validate :validate_function_structure

              def to_h
                super.tap do |hash|
                  hash[:function] = function if function.present?
                end
              end

              private

              def validate_function_structure
                if function.blank?
                  errors.add(:function, "must be present")
                  return
                end

                unless function.is_a?(Hash)
                  errors.add(:function, "must be a hash")
                  return
                end

                unless function[:name].present?
                  errors.add(:function, "must include 'name' field")
                end

                if function[:name].present?
                  if function[:name].length > 64
                    errors.add(:function, "name must be 64 characters or less")
                  end

                  unless function[:name] =~ /^[a-zA-Z0-9_-]+$/
                    errors.add(:function, "name must contain only a-z, A-Z, 0-9, underscores and dashes")
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
