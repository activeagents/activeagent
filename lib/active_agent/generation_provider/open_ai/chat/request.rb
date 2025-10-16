# frozen_string_literal: true

require_relative "../../common/_base_model"
require_relative "requests/types"
require_relative "requests/audio"
require_relative "requests/response_format"
require_relative "requests/prediction"
require_relative "requests/stream_options"
require_relative "requests/web_search_options"
require_relative "requests/tool"
require_relative "requests/tool_choice"
require_relative "requests/message"

module ActiveAgent
  module GenerationProvider
    module OpenAI
      module Chat
        class Request < Common::BaseModel
          # Messages array (required)
          attribute :messages, Requests::Types::MessagesType.new

          # Model ID (required)
          attribute :model, :string

          # Audio output parameters
          attribute :audio, Requests::Types::AudioType.new

          # Frequency penalty
          attribute :frequency_penalty, :float, default: 0

          # Deprecated: function_call (use tool_choice instead)
          attribute :function_call # String or object

          # Deprecated: functions (use tools instead)
          attribute :functions # Array of function objects

          # Logit bias
          attribute :logit_bias # Hash of token_id => bias_value

          # Log probabilities
          attribute :logprobs, :boolean, default: false

          # Max completion tokens
          attribute :max_completion_tokens, :integer

          # Deprecated: max_tokens (use max_completion_tokens)
          attribute :max_tokens, :integer

          # Metadata
          attribute :metadata # Hash of key-value pairs

          # Modalities
          attribute :modalities, default: -> { [ "text" ] } # Array of strings

          # Number of completions
          attribute :n, :integer, default: 1

          # Parallel tool calls
          attribute :parallel_tool_calls, :boolean, default: true

          # Prediction configuration
          attribute :prediction, Requests::Types::PredictionType.new

          # Presence penalty
          attribute :presence_penalty, :float, default: 0

          # Prompt cache key
          attribute :prompt_cache_key, :string

          # Reasoning effort (for reasoning models)
          attribute :reasoning_effort, :string

          # Response format
          attribute :response_format, Requests::Types::ResponseFormatType.new

          # Safety identifier
          attribute :safety_identifier, :string

          # Deprecated: seed
          attribute :seed, :integer

          # Service tier
          attribute :service_tier, :string, default: "auto"

          # Stop sequences
          attribute :stop # String, array, or null

          # Storage
          attribute :store, :boolean, default: false

          # Streaming
          attribute :stream, :boolean, default: false
          attribute :stream_options, Requests::Types::StreamOptionsType.new

          # Temperature sampling
          attribute :temperature, :float, default: 1

          # Tool choice
          attribute :tool_choice, Requests::Types::ToolChoiceType.new

          # Tools array
          attribute :tools # Array of tool objects

          # Top logprobs
          attribute :top_logprobs, :integer

          # Top P sampling
          attribute :top_p, :float, default: 1

          # Deprecated: user (use safety_identifier or prompt_cache_key)
          attribute :user, :string

          # Verbosity (for reasoning models)
          attribute :verbosity, :string

          # Web search options
          attribute :web_search_options, Requests::Types::WebSearchOptionsType.new

          # Validations
          validates :model, :messages, presence: true

          validates :frequency_penalty,     numericality: { greater_than_or_equal_to: -2.0, less_than_or_equal_to: 2.0 }, allow_nil: true
          validates :presence_penalty,      numericality: { greater_than_or_equal_to: -2.0, less_than_or_equal_to: 2.0 }, allow_nil: true
          validates :temperature,           numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 2 },      allow_nil: true
          validates :top_p,                 numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },      allow_nil: true
          validates :top_logprobs,          numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 20 },     allow_nil: true
          validates :n,                     numericality: { greater_than: 0 },                                            allow_nil: true
          validates :max_completion_tokens, numericality: { greater_than: 0 },                                            allow_nil: true
          validates :max_tokens,            numericality: { greater_than: 0 },                                            allow_nil: true

          validates :service_tier,     inclusion: { in: %w[auto default flex priority] }, allow_nil: true
          validates :reasoning_effort, inclusion: { in: %w[minimal low medium high] },    allow_nil: true
          validates :verbosity,        inclusion: { in: %w[low medium high] },            allow_nil: true
          validates :modalities,       inclusion: { in: %w[text audio] },                 allow_nil: true

          # Custom validations
          validate :validate_metadata_format
          validate :validate_logit_bias_format
          validate :validate_stop_sequences

          def to_h
            super.tap do |hash|
              # Convert nested objects to hashes
              hash[:audio]              = audio.to_h              if audio.is_a?(Requests::Audio)
              hash[:response_format]    = response_format.to_h    if response_format.is_a?(Requests::ResponseFormat)
              hash[:prediction]         = prediction.to_h         if prediction.is_a?(Requests::Prediction)
              hash[:stream_options]     = stream_options.to_h     if stream_options.is_a?(Requests::StreamOptions)
              hash[:web_search_options] = web_search_options.to_h if web_search_options.is_a?(Requests::WebSearchOptions)
              hash[:tool_choice]        = tool_choice.to_h        if tool_choice.is_a?(Requests::ToolChoice)

              # Convert messages array
              if messages.is_a?(Array)
                hash[:messages] = messages.map do |message|
                  message.is_a?(Requests::Messages::Base) ? message.to_h : message
                end
              end

              # Convert tools array
              if tools.is_a?(Array)
                hash[:tools] = tools.map do |tool|
                  tool.is_a?(Requests::Tools::Base) ? tool.to_h : tool
                end
              end
            end
          end

          def to_hc
            super.tap do |hash|
              # Can be an empty hash, to enable the feature
              hash[:web_search_options] = web_search_options.to_h if web_search_options.is_a?(Requests::WebSearchOptions)
            end
          end

          # Handle message assignment from common format
          def message=(value)
            self.messages ||= []

            self.messages << {
              role:    value.role,
              content: value.content
            }
          end

          # Handle multiple messages assignment
          def messages=(value)
            case value
            when Array
              super(value)
            else
              super([ value ])
            end
          end

          private

          def validate_metadata_format
            return if metadata.nil?

            unless metadata.is_a?(Hash)
              errors.add(:metadata, "must be a hash")
              return
            end

            metadata.each do |key, value|
              if key.to_s.length > 64
                errors.add(:metadata, "keys must be 64 characters or less")
              end
              if value.to_s.length > 512
                errors.add(:metadata, "values must be 512 characters or less")
              end
            end

            if metadata.size > 16
              errors.add(:metadata, "must have 16 key-value pairs or less")
            end
          end

          def validate_logit_bias_format
            return if logit_bias.nil?

            unless logit_bias.is_a?(Hash)
              errors.add(:logit_bias, "must be a hash")
              return
            end

            logit_bias.each do |token_id, bias|
              unless bias.is_a?(Numeric) && bias >= -100 && bias <= 100
                errors.add(:logit_bias, "bias values must be between -100 and 100")
              end
            end
          end

          def validate_stop_sequences
            return if stop.nil?
            return if stop.is_a?(String)

            if stop.is_a?(Array)
              errors.add(:stop, "can have at most 4 sequences") if stop.length > 4
            else
              errors.add(:stop, "must be a string, array, or null")
            end
          end
        end
      end
    end
  end
end
