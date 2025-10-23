# frozen_string_literal: true

require_relative "messages/_types"
require_relative "thinking_config/_types"
require_relative "tool_choice/_types"
require_relative "tool_choice/_types"

require_relative "container_params"
require_relative "context_management_config"
require_relative "metadata"
require_relative "response_format"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        # ActiveModel type for casting and serializing ContainerParams objects.
        #
        # Supports string shortcut for container ID: `"container_id"` casts to `{ id: "container_id" }`.
        class ContainerParamsType < ActiveModel::Type::Value
          # @param value [ContainerParams, Hash, String, nil]
          # @return [ContainerParams, nil]
          # @raise [ArgumentError] when value cannot be cast
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

          # @param value [ContainerParams, Hash, nil]
          # @return [Hash, nil]
          # @raise [ArgumentError] when value cannot be serialized
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

          # @param value [Object]
          # @return [ContainerParams, nil]
          def deserialize(value)
            cast(value)
          end
        end

        # ActiveModel type for casting and serializing ContextManagementConfig objects.
        class ContextManagementConfigType < ActiveModel::Type::Value
          # @param value [ContextManagementConfig, Hash, nil]
          # @return [ContextManagementConfig, nil]
          # @raise [ArgumentError] when value cannot be cast
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

          # @param value [ContextManagementConfig, Hash, nil]
          # @return [Hash, nil]
          # @raise [ArgumentError] when value cannot be serialized
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

          # @param value [Object]
          # @return [ContextManagementConfig, nil]
          def deserialize(value)
            cast(value)
          end
        end

        # ActiveModel type for casting and serializing Metadata objects.
        class MetadataType < ActiveModel::Type::Value
          # @param value [Metadata, Hash, nil]
          # @return [Metadata, nil]
          # @raise [ArgumentError] when value cannot be cast
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

          # @param value [Metadata, Hash, nil]
          # @return [Hash, nil]
          # @raise [ArgumentError] when value cannot be serialized
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

          # @param value [Object]
          # @return [Metadata, nil]
          def deserialize(value)
            cast(value)
          end
        end

        # ActiveModel type for casting and serializing ResponseFormat objects.
        #
        # @see ResponseFormat
        class ResponseFormatType < ActiveModel::Type::Value
          # @param value [ResponseFormat, Hash, nil]
          # @return [ResponseFormat, nil]
          # @raise [ArgumentError] when value cannot be cast
          def cast(value)
            case value
            when ResponseFormat
              value
            when Hash
              ResponseFormat.new(**value.deep_symbolize_keys)
            when nil
              nil
            else
              raise ArgumentError, "Cannot cast #{value.class} to ResponseFormat"
            end
          end

          # @param value [ResponseFormat, Hash, nil]
          # @return [Hash, nil]
          # @raise [ArgumentError] when value cannot be serialized
          def serialize(value)
            case value
            when ResponseFormat
              value.serialize
            when Hash
              value
            when nil
              nil
            else
              raise ArgumentError, "Cannot serialize #{value.class}"
            end
          end

          # @param value [Object]
          # @return [ResponseFormat, nil]
          def deserialize(value)
            cast(value)
          end
        end
      end
    end
  end
end
