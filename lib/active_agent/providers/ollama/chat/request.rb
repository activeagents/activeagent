# frozen_string_literal: true

require_relative "../../open_ai/chat/request"
require_relative "requests/_types"

module ActiveAgent
  module Providers
    module Ollama
      module Chat
        # Ollama uses the same request structure as OpenAI's chat completion API
        # This class exists to allow for Ollama-specific customizations.
        class Request < OpenAI::Chat::Request
          # Messages array (required)
          attribute :messages, Requests::Messages::MessagesType.new

          # Ollama-specific parameters

          # Format: return response in json or as a JSON schema
          # Can be "json" or a JSON schema object
          attribute :format

          # Options: additional model parameters (temperature, num_predict, etc.)
          # Hash of key-value pairs for model-specific options
          attribute :options

          # Keep alive: controls how long the model stays loaded in memory
          # String duration (e.g., "5m", "1h") or integer in seconds
          # Default: "5m"
          attribute :keep_alive

          # Raw: if true, no formatting will be applied to the prompt
          # You may use this if you are specifying a full templated prompt
          attribute :raw, :boolean, default: false

          # Validations for Ollama-specific parameters
          validate :validate_format
          validate :validate_options_format

          # Common Format Compatability
          def messages=(value)
            case value
            when Array
              super((messages || []) | value)
            else
              super((messages || []) | [ value ])
            end
          end

          private

          def validate_format
            return if format.nil?
            return if format == "json"
            return if format.is_a?(Hash) # JSON schema object

            errors.add(:format, "must be 'json' or a JSON schema object")
          end

          def validate_options_format
            return if options.nil?

            unless options.is_a?(Hash)
              errors.add(:options, "must be a hash of model parameters")
            end
          end
        end
      end
    end
  end
end
