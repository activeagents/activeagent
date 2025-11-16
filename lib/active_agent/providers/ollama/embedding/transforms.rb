# frozen_string_literal: true

require "json"

module ActiveAgent
  module Providers
    module Ollama
      # Handles transformation and normalization of embedding request parameters
      # for the Ollama Embeddings API
      module Embedding
        # Provides transformation methods for normalizing embedding parameters
        # to Ollama API format with OpenAI gem compatibility
        module Transforms
          class << self
            # Converts gem objects to hash representation
            #
            # @param obj [Object] gem object or primitive value
            # @return [Hash, Object] hash if object supports JSON serialization
            def gem_to_hash(obj)
              if obj.respond_to?(:to_json)
                JSON.parse(obj.to_json, symbolize_names: true)
              else
                obj
              end
            end

            # Normalizes all embedding request parameters
            #
            # Ollama-specific parameters (options, keep_alive, truncate) are extracted
            # and returned separately from OpenAI-compatible parameters.
            #
            # @param params [Hash] raw request parameters
            # @return [Array<Hash, Hash>] tuple of [openai_params, ollama_params]
            def normalize_params(params)
              params = params.dup

              # Extract Ollama-specific parameters
              ollama_params = {}
              ollama_params[:options] = params.delete(:options) if params.key?(:options)
              ollama_params[:keep_alive] = params.delete(:keep_alive) if params.key?(:keep_alive)
              ollama_params[:truncate] = params.delete(:truncate) if params.key?(:truncate)

              # Extract options attributes that can be at top level
              extract_option_attributes(params, ollama_params)

              # Normalize input - Ollama only accepts strings, not token arrays
              if params[:input]
                params[:input] = normalize_input(params[:input])
              end

              [ params, ollama_params ]
            end

            # Normalizes input parameter to Ollama format
            #
            # Ollama only accepts strings or arrays of strings (no token arrays).
            # Converts single string to array internally for consistency.
            #
            # @param input [String, Array<String>]
            # @return [Array<String>] normalized input as array of strings
            # @raise [ArgumentError] if input contains non-string values
            def normalize_input(input)
              case input
              when String
                [ input.presence ].compact
              when Array
                # Validate all elements are strings
                input.each_with_index do |item, index|
                  unless item.is_a?(String)
                    raise ArgumentError, "Ollama embedding input must contain only strings, got #{item.class} at index #{index}"
                  end
                  if item.empty?
                    raise ArgumentError, "Ollama embedding input cannot contain empty strings at index #{index}"
                  end
                end
                input.compact
              when nil
                nil
              else
                raise ArgumentError, "Cannot normalize #{input.class} to Ollama input (expected String or Array)"
              end
            end

            # Serializes input for API submission
            #
            # Returns single string if array has only one element, otherwise array.
            #
            # @param input [Array<String>, nil]
            # @return [String, Array<String>, nil]
            def serialize_input(input)
              return nil if input.nil?

              # Return single string if array has only one element
              if input.is_a?(Array) && input.length == 1
                input.first
              else
                input
              end
            end

            # Cleans up serialized request for API submission
            #
            # Merges OpenAI-compatible params with Ollama-specific params.
            #
            # @param openai_hash [Hash] serialized OpenAI-compatible request
            # @param ollama_params [Hash] Ollama-specific parameters
            # @param defaults [Hash] default values to remove
            # @return [Hash] cleaned and merged request hash
            def cleanup_serialized_request(openai_hash, ollama_params, defaults)
              # Remove nil values
              cleaned = openai_hash.compact

              # Serialize input (convert single-element array to string)
              if cleaned[:input]
                cleaned[:input] = serialize_input(cleaned[:input])
              end

              # Merge Ollama-specific params, skip defaults
              ollama_params.each do |key, value|
                next if value.nil?
                next if value.respond_to?(:empty?) && value.empty?
                next if defaults.key?(key) && defaults[key] == value

                # Serialize options object if present
                cleaned[key] = if value.respond_to?(:serialize)
                  value.serialize
                else
                  value
                end
              end

              cleaned
            end

            private

            # Extracts option attributes that can be specified at the top level
            #
            # @param params [Hash] request parameters
            # @param ollama_params [Hash] ollama-specific parameters to populate
            def extract_option_attributes(params, ollama_params)
              option_keys = [
                :mirostat, :mirostat_eta, :mirostat_tau, :num_ctx,
                :repeat_last_n, :repeat_penalty, :temperature, :seed,
                :num_predict, :top_k, :top_p, :min_p, :stop
              ]

              option_keys.each do |key|
                if params.key?(key)
                  ollama_params[:options] ||= {}
                  ollama_params[:options][key] = params.delete(key)
                end
              end
            end
          end
        end
      end
    end
  end
end
