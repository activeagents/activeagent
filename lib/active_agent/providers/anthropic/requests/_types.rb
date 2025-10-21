# frozen_string_literal: true

require_relative "messages/_types"
require_relative "thinking_config/_types"
require_relative "tool_choice/_types"
require_relative "tool_choice/_types"

require_relative "container_params"
require_relative "context_management_config"
require_relative "metadata"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        # Type for ContainerParams
        class ContainerParamsType < ActiveModel::Type::Value
          def cast(value)
            case value
            when ContainerParams
              value
            when Hash
              ContainerParams.new(**value.deep_symbolize_keys)
            when String
              # Allow string as container ID shortcut
              ContainerParams.new(id: value)
            when nil
              nil
            else
              raise ArgumentError, "Cannot cast #{value.class} to ContainerParams"
            end
          end

          def serialize(value)
            case value
            when ContainerParams
              value.serialize
            when Hash
              value
            when nil
              nil
            else
              raise ArgumentError, "Cannot serialize #{value.class}"
            end
          end

          def deserialize(value)
            cast(value)
          end
        end

        # Type for ContextManagementConfig
        class ContextManagementConfigType < ActiveModel::Type::Value
          def cast(value)
            case value
            when ContextManagementConfig
              value
            when Hash
              ContextManagementConfig.new(**value.deep_symbolize_keys)
            when nil
              nil
            else
              raise ArgumentError, "Cannot cast #{value.class} to ContextManagementConfig"
            end
          end

          def serialize(value)
            case value
            when ContextManagementConfig
              value.serialize
            when Hash
              value
            when nil
              nil
            else
              raise ArgumentError, "Cannot serialize #{value.class}"
            end
          end

          def deserialize(value)
            cast(value)
          end
        end

        # Type for Metadata
        class MetadataType < ActiveModel::Type::Value
          def cast(value)
            case value
            when Metadata
              value
            when Hash
              Metadata.new(**value.deep_symbolize_keys)
            when nil
              nil
            else
              raise ArgumentError, "Cannot cast #{value.class} to Metadata"
            end
          end

          def serialize(value)
            case value
            when Metadata
              value.serialize
            when Hash
              value
            when nil
              nil
            else
              raise ArgumentError, "Cannot serialize #{value.class}"
            end
          end

          def deserialize(value)
            cast(value)
          end
        end
      end
    end
  end
end
