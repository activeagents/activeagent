# frozen_string_literal: true

module ActiveAgent
  module Providers
    module OpenAI
      # Handles transformation and normalization of embedding request parameters
      # for the OpenAI Embeddings API
      module Embedding
        # Provides transformation methods for normalizing embedding parameters
        # to OpenAI gem's native format
        module Transforms
          # Converts OpenAI gem objects to hash representation
          #
          # @param obj [Object] gem object or primitive value
          # @return [Hash, Object] hash if object supports JSON serialization, otherwise original object
          def self.gem_to_hash(obj)
            if obj.respond_to?(:to_json)
              JSON.parse(obj.to_json)
            else
              obj
            end
          end

          # Normalizes all embedding request parameters
          #
          # @param params [Hash] raw request parameters
          # @return [Hash] normalized parameters
          def self.normalize_params(params)
            normalized = params.dup

            if normalized[:input]
              normalized[:input] = normalize_input(normalized[:input])
            end

            normalized
          end

          # Normalizes input parameter to supported format
          #
          # Handles multiple input formats:
          # - `"text"` - single string for one embedding
          # - `["text1", "text2"]` - array of strings for multiple embeddings
          # - `[1, 2, 3]` - token array for single embedding
          # - `[[1, 2], [3, 4]]` - array of token arrays for multiple embeddings
          #
          # @param input [String, Array<String>, Array<Integer>, Array<Array<Integer>>]
          # @return [String, Array] normalized input in gem-compatible format
          def self.normalize_input(input)
            case input
            when String
              input
            when Array
              if input.empty?
                input
              elsif input.first.is_a?(Integer)
                input
              elsif input.first.is_a?(Array)
                input
              else
                input
              end
            else
              input
            end
          end

          # Removes nil values from serialized request
          #
          # @param serialized [Hash] serialized request
          # @param defaults [Hash] default values to remove
          # @param gem_object [Object] original gem object (unused but for consistency)
          # @return [Hash] cleaned request hash
          def self.cleanup_serialized_request(serialized, defaults = {}, gem_object = nil)
            # Remove nil values
            cleaned = serialized.compact

            # Remove default values
            defaults.each do |key, value|
              cleaned.delete(key) if cleaned[key] == value
            end

            cleaned
          end
        end
      end
    end
  end
end
