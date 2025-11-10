# frozen_string_literal: true

require "active_agent/providers/common/model"
require_relative "requests/_types"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        class Request < Common::BaseModel
          # Background execution
          attribute :background, :boolean, default: false

          # Conversation
          attribute :conversation, Requests::ConversationType.new

          # Include additional output data
          attribute :include, default: -> { [] } # Array of strings

          # Input items (text, image, or file inputs)
          attribute :input, Requests::Inputs::MessagesType.new

          # Instructions (system/developer message)
          attribute :instructions, :string

          # Token limits
          attribute :max_output_tokens, :integer
          attribute :max_tool_calls, :integer

          # Metadata
          attribute :metadata # Hash of key-value pairs

          # Model ID
          attribute :model, :string

          # Parallel tool calls
          attribute :parallel_tool_calls, :boolean, default: true

          # Previous response ID for multi-turn conversations
          attribute :previous_response_id, :string

          # Prompt template reference
          attribute :prompt, Requests::PromptReferenceType.new

          # Cache key for optimization
          attribute :prompt_cache_key, :string

          # Reasoning configuration (for o-series and gpt-5 models)
          attribute :reasoning, Requests::ReasoningType.new

          # Safety identifier for usage policy detection
          attribute :safety_identifier, :string

          # Service tier
          attribute :service_tier, :string, default: "auto"

          # Storage
          attribute :store, :boolean, default: true

          # Streaming
          attribute :stream, :boolean, default: false
          attribute :stream_options, Requests::StreamOptionsType.new

          # Temperature sampling
          attribute :temperature, :float, default: 1

          # Text response configuration
          attribute :text, Requests::TextType.new

          # Tool choice
          attribute :tool_choice, Requests::ToolChoiceType.new

          # Tools array
          attribute :tools, Requests::Tools::ToolsType.new

          # Top logprobs
          attribute :top_logprobs, :integer

          # Top P sampling
          attribute :top_p, :float, default: 1

          # Truncation strategy
          attribute :truncation, :string, default: "disabled"

          # User identifier (deprecated, use safety_identifier or prompt_cache_key)
          attribute :user, :string

          # Validations
          validates :max_output_tokens, numericality: { greater_than: 0 },                                        allow_nil: true
          validates :max_tool_calls,    numericality: { greater_than: 0 },                                        allow_nil: true
          validates :temperature,       numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 2 },  allow_nil: true
          validates :top_p,             numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },  allow_nil: true
          validates :top_logprobs,      numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 20 }, allow_nil: true
          validates :service_tier,      inclusion: { in: %w[auto default flex priority] },                        allow_nil: true
          validates :truncation,        inclusion: { in: %w[auto disabled] },                                     allow_nil: true

          validate :validate_conversation_exclusivity
          validate :validate_metadata_format
          validate :validate_include_values

          # Common Format Mapping
          alias_attribute :messages,        :input
          alias_attribute :message,         :input
          alias_attribute :response_format, :text

          # Common Format Compatability
          def instructions=(value)
            super(value.is_a?(Array) ? value.join("\n") : value)
          end

          private

          def validate_conversation_exclusivity
            if conversation.present? && previous_response_id.present?
              errors.add(:base, "Cannot use both conversation and previous_response_id")
            end
          end

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

          def validate_include_values
            return if include.nil? || include.empty?

            valid_include_values = [
              "web_search_call.action.sources",
              "code_interpreter_call.outputs",
              "computer_call_output.output.image_url",
              "file_search_call.results",
              "message.input_image.image_url",
              "message.output_text.logprobs",
              "reasoning.encrypted_content"
            ]

            invalid_values = include - valid_include_values
            if invalid_values.any?
              errors.add(:include, "contains invalid values: #{invalid_values.join(', ')}")
            end
          end
        end
      end
    end
  end
end
