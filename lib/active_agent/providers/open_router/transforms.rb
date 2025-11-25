# frozen_string_literal: true

require "active_support/core_ext/hash/keys"
require_relative "../open_ai/chat/transforms"

module ActiveAgent
  module Providers
    module OpenRouter
      # Provides transformation methods for normalizing OpenRouter parameters
      # to work with OpenAI gem's native format plus OpenRouter extensions
      #
      # Leverages OpenAI::Chat::Transforms for base message normalization while
      # adding handling for OpenRouter-specific parameters like plugins, provider
      # preferences, and model fallbacks.
      module Transforms
        class << self
          # Converts gem model object to hash via JSON round-trip
          #
          # @param gem_object [Object]
          # @return [Hash] with symbolized keys
          def gem_to_hash(gem_object)
            OpenAI::Chat::Transforms.gem_to_hash(gem_object)
          end

          # Normalizes all request parameters for OpenRouter API
          #
          # Handles both OpenAI-compatible parameters and OpenRouter-specific extensions.
          # OpenRouter-specific params (plugins, provider, transforms, models, route) are
          # extracted and returned separately for manual serialization.
          #
          # @param params [Hash]
          # @return [Array<Hash, Hash>] tuple of [openai_params, openrouter_params]
          def normalize_params(params)
            params = params.dup

            # Extract OpenRouter-specific parameters
            openrouter_params = {}
            openrouter_params[:plugins] = params.delete(:plugins) if params.key?(:plugins)
            openrouter_params[:provider] = params.delete(:provider) if params.key?(:provider)
            openrouter_params[:transforms] = params.delete(:transforms) if params.key?(:transforms)
            openrouter_params[:models] = params.delete(:models) if params.key?(:models)
            openrouter_params[:route] = params.delete(:route) if params.key?(:route)

            # Extract OpenRouter-specific sampling parameters not in OpenAI
            openrouter_params[:top_k] = params.delete(:top_k) if params.key?(:top_k)
            openrouter_params[:min_p] = params.delete(:min_p) if params.key?(:min_p)
            openrouter_params[:top_a] = params.delete(:top_a) if params.key?(:top_a)
            openrouter_params[:repetition_penalty] = params.delete(:repetition_penalty) if params.key?(:repetition_penalty)

            # Handle response_format special logic for OpenRouter
            # OpenRouter requires provider.require_parameters=true for structured output
            if params[:response_format]
              response_format = params[:response_format]
              response_format_hash = response_format.is_a?(Hash) ? response_format : { type: response_format }

              if %i[json_object json_schema].include?(response_format_hash[:type].to_sym)
                openrouter_params[:provider] ||= {}
                openrouter_params[:provider][:require_parameters] = true
              end
            end

            # Use OpenAI transforms for the base parameters
            openai_params = OpenAI::Chat::Transforms.normalize_params(params)

            # Override tool_choice normalization for OpenRouter's "any" vs "required" difference
            if openai_params[:tool_choice]
              openai_params[:tool_choice] = normalize_tool_choice(openai_params[:tool_choice])
            end

            [ openai_params, openrouter_params ]
          end

          # Normalizes tools using OpenAI transforms
          #
          # @param tools [Array<Hash>]
          # @return [Array<Hash>]
          def normalize_tools(tools)
            OpenAI::Chat::Transforms.normalize_tools(tools)
          end

          # Normalizes tool_choice for OpenRouter API differences
          #
          # OpenRouter uses "any" instead of OpenAI's "required" for forcing tool use.
          # Converts common format to OpenRouter-specific format:
          # - "required" (common) → "any" (OpenRouter)
          # - Everything else delegates to OpenAI transforms
          #
          # @param tool_choice [String, Hash, Symbol]
          # @return [String, Hash, Symbol]
          def normalize_tool_choice(tool_choice)
            # Convert "required" to OpenRouter's "any"
            return "any" if tool_choice.to_s == "required"

            # For everything else, use OpenAI transforms
            OpenAI::Chat::Transforms.normalize_tool_choice(tool_choice)
          end

          # Normalizes messages using OpenAI transforms
          #
          # @param messages [Array, String, Hash, nil]
          # @return [Array<OpenAI::Models::Chat::ChatCompletionMessageParam>, nil]
          def normalize_messages(messages)
            OpenAI::Chat::Transforms.normalize_messages(messages)
          end

          # Normalizes response_format for OpenRouter
          #
          # Delegates to OpenAI transforms. The special handling for structured output
          # (setting provider.require_parameters=true) is handled in normalize_params.
          #
          # @param format [Hash, Symbol, String]
          # @return [Hash]
          def normalize_response_format(format)
            OpenAI::Chat::Transforms.normalize_response_format(format)
          end

          # Cleans up serialized request for API submission
          #
          # Merges OpenAI-compatible params with OpenRouter-specific params.
          #
          # @param openai_hash [Hash] serialized OpenAI request
          # @param openrouter_params [Hash] OpenRouter-specific parameters
          # @param defaults [Hash] default values to remove
          # @param gem_object [Object] original gem object
          # @return [Hash] cleaned and merged request hash
          def cleanup_serialized_request(openai_hash, openrouter_params, defaults, gem_object)
            # Start with OpenAI cleanup
            cleaned = OpenAI::Chat::Transforms.cleanup_serialized_request(openai_hash, defaults, gem_object)

            # Merge OpenRouter-specific params, but skip default values
            openrouter_params.each do |key, value|
              # Skip if value is nil, empty, or matches the default
              next if value.nil?
              next if value.respond_to?(:empty?) && value.empty?
              next if defaults.key?(key) && defaults[key] == value

              cleaned[key] = serialize_openrouter_param(key, value)
            end

            cleaned
          end

          # Serializes OpenRouter-specific parameters
          #
          # @param key [Symbol]
          # @param value [Object]
          # @return [Object] serialized value
          def serialize_openrouter_param(key, value)
            case key
            when :provider
              # Serialize provider preferences object
              value.respond_to?(:serialize) ? value.serialize : value
            when :plugins
              # Serialize plugins array
              value.respond_to?(:map) ? value.map { |p| p.respond_to?(:serialize) ? p.serialize : p } : value
            else
              value
            end
          end
        end
      end
    end
  end
end
