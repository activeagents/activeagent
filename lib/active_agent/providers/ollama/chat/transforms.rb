# frozen_string_literal: true

require "active_support/core_ext/hash/keys"
require_relative "../../open_ai/chat/transforms"

module ActiveAgent
  module Providers
    module Ollama
      module Chat
        # Provides transformation methods for normalizing Ollama parameters
        # to work with OpenAI gem's native format plus Ollama extensions
        #
        # Leverages OpenAI::Chat::Transforms for base message normalization while
        # adding handling for Ollama-specific parameters like format, options,
        # keep_alive, and raw mode.
        module Transforms
          class << self
            # Converts gem model object to hash via JSON round-trip
            #
            # @param gem_object [Object]
            # @return [Hash] with symbolized keys
            def gem_to_hash(gem_object)
              OpenAI::Chat::Transforms.gem_to_hash(gem_object)
            end

            # Normalizes all request parameters for Ollama API
            #
            # Handles both OpenAI-compatible parameters and Ollama-specific extensions.
            # Ollama-specific params (format, options, keep_alive, raw) are
            # extracted and returned separately for manual serialization.
            #
            # @param params [Hash]
            # @return [Array<Hash, Hash>] tuple of [openai_params, ollama_params]
            def normalize_params(params)
              params = params.dup

              # Extract Ollama-specific parameters
              ollama_params = {}
              ollama_params[:format] = params.delete(:format) if params.key?(:format)
              ollama_params[:options] = params.delete(:options) if params.key?(:options)
              ollama_params[:keep_alive] = params.delete(:keep_alive) if params.key?(:keep_alive)
              ollama_params[:raw] = params.delete(:raw) if params.key?(:raw)

              # Use OpenAI transforms for the base parameters
              openai_params = OpenAI::Chat::Transforms.normalize_params(params)

              [ openai_params, ollama_params ]
            end

            # Normalizes messages using OpenAI transforms
            #
            # @param messages [Array, String, Hash, nil]
            # @return [Array<OpenAI::Models::Chat::ChatCompletionMessageParam>, nil]
            def normalize_messages(messages)
              OpenAI::Chat::Transforms.normalize_messages(messages)
            end

            # Normalizes instructions using OpenAI transforms
            #
            # @param instructions [Array<String>, String]
            # @return [Array<OpenAI::Models::Chat::ChatCompletionMessageParam>]
            def normalize_instructions(instructions)
              OpenAI::Chat::Transforms.normalize_instructions(instructions)
            end

            # Cleans up serialized request for API submission
            #
            # Merges OpenAI-compatible params with Ollama-specific params.
            # Also groups consecutive same-role messages as required by Ollama.
            #
            # @param openai_hash [Hash] serialized OpenAI request
            # @param ollama_params [Hash] Ollama-specific parameters
            # @param defaults [Hash] default values to remove
            # @param gem_object [Object] original gem object
            # @return [Hash] cleaned and merged request hash
            def cleanup_serialized_request(openai_hash, ollama_params, defaults, gem_object)
              # Start with OpenAI cleanup
              cleaned = OpenAI::Chat::Transforms.cleanup_serialized_request(openai_hash, defaults, gem_object)

              # Group consecutive same-role messages for Ollama
              if cleaned[:messages]
                cleaned[:messages] = group_same_role_messages(cleaned[:messages])
              end

              # Merge Ollama-specific params, but skip default values
              ollama_params.each do |key, value|
                # Skip if value is nil, empty, or matches the default
                next if value.nil?
                next if value.respond_to?(:empty?) && value.empty?
                next if defaults.key?(key) && defaults[key] == value

                cleaned[key] = value
              end

              cleaned
            end

            # Groups consecutive same-role messages for Ollama
            #
            # Ollama requires consecutive messages with the same role to be merged
            # by concatenating their content.
            #
            # @param messages [Array<Hash>] array of message hashes
            # @return [Array<Hash>] grouped messages
            def group_same_role_messages(messages)
              return [] if messages.nil? || messages.empty?

              grouped = []
              messages.each do |message|
                if grouped.empty? || grouped.last[:role] != message[:role]
                  grouped << message.deep_dup
                else
                  # Concatenate content for same-role messages
                  last_content = grouped.last[:content]
                  new_content = message[:content]

                  grouped.last[:content] = if last_content.is_a?(Array) && new_content.is_a?(Array)
                    last_content + new_content
                  elsif last_content.is_a?(String) && new_content.is_a?(String)
                    last_content + new_content
                  else
                    # Mix of types, convert to array
                    Array(last_content) + Array(new_content)
                  end
                end
              end

              grouped
            end
          end
        end
      end
    end
  end
end
