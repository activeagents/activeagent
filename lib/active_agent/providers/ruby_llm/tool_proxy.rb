# frozen_string_literal: true

module ActiveAgent
  module Providers
    module RubyLLM
      # Bridges ActiveAgent tool definitions to RubyLLM's expected tool interface.
      # RubyLLM expects tools as { "name" => tool } where each tool responds to
      # #name, #description, #parameters, #params_schema, and #provider_params.
      class ToolProxy
        attr_reader :name, :description, :parameters

        def initialize(name:, description:, parameters:)
          @name = name
          @description = description
          @parameters = parameters
        end

        # RubyLLM checks this first; returns the JSON Schema directly so
        # RubyLLM doesn't try to interpret our parameters as Parameter objects.
        # Deep-stringifies keys to match RubyLLM's internal schema format.
        def params_schema
          deep_stringify(@parameters) if @parameters.is_a?(Hash) && @parameters.any?
        end

        # RubyLLM merges this into the tool definition
        def provider_params
          {}
        end

        private

        def deep_stringify(obj)
          case obj
          when Hash
            obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
          when Array
            obj.map { |v| deep_stringify(v) }
          else
            obj
          end
        end
      end
    end
  end
end
