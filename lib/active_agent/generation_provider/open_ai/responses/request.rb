# frozen_string_literal: true

require_relative "../../common/_base_model"
require_relative "types"
require_relative "conversation"
require_relative "prompt_reference"
require_relative "reasoning"
require_relative "stream_options"
require_relative "text"

module ActiveAgent
  module GenerationProvider
    module OpenAI
      module Responses
        class Request < Common::BaseModel
          # Background execution
          attribute :background, :boolean, default: false

          # Conversation
          attribute :conversation, Types::ConversationType.new

          # Include additional output data
          attribute :include, default: -> { [] } # Array of strings

          # Input items (text, image, or file inputs)
          attribute :input # Can be string or array

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
          attribute :prompt, Types::PromptReferenceType.new

          # Cache key for optimization
          attribute :prompt_cache_key, :string

          # Reasoning configuration (for o-series and gpt-5 models)
          attribute :reasoning, Types::ReasoningType.new

          # Safety identifier for usage policy detection
          attribute :safety_identifier, :string

          # Service tier
          attribute :service_tier, :string, default: "auto"

          # Storage
          attribute :store, :boolean, default: true

          # Streaming
          attribute :stream, :boolean, default: false
          attribute :stream_options, Types::StreamOptionsType.new

          # Temperature sampling
          attribute :temperature, :float, default: 1

          # Text response configuration
          attribute :text, Types::TextType.new

          # Tool choice
          attribute :tool_choice # Can be string or object

          # Tools array
          attribute :tools # Array of tool objects

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

          # Custom validation: conversation and previous_response_id are mutually exclusive
          validate :validate_conversation_exclusivity

          # Custom validation: metadata keys and values length
          validate :validate_metadata_format

          # Custom validation: include array values
          validate :validate_include_values

          def to_h
            super.tap do |hash|
              # Convert nested objects to hashes
              hash[:conversation]   = conversation.to_h   if conversation.is_a?(Conversation)
              hash[:prompt]         = prompt.to_h         if prompt.is_a?(PromptReference)
              hash[:reasoning]      = reasoning.to_h      if reasoning.is_a?(Reasoning)
              hash[:stream_options] = stream_options.to_h if stream_options.is_a?(StreamOptions)
              hash[:text]           = text.to_h           if text.is_a?(Text)
            end
          end

          # To handle native input format
          def input=(value)
            case value
            when String, Array
              super(value)
            when Hash
              super([ value ])
            else
              fail "Unexpected Input Type for #{value}"
            end
          end

          # To handle Common Message [input] format
          def message=(value)
            case value.role
            when :system
              self.instructions = value.content
            when :user
              self.input = value.content
            end

            # self.input = [
            #   {
            #     role:    value.role,
            #     content: message_content(value.content)
            #   }
            # ]
          end

          # To handle Common Messages [input] format
          def messages=(value)
            value.each do |message|
              self.message = message
            end
          end

          private

          def message_content(value)
            return value unless value.is_a?(Array)

            value.map do |content_part|
              prompt_messages_content_typed(content_part)
            end.compact
          end

          # To Convert to Common Message Content Types to OpenAI
          def message_content_typed(value)
            case value
            when String
              { type: "input_text", text: value }
            when ActiveAgent::ActionPrompt::Message
              if value.content_type == "input_text"
                { type: "input_text", text: value.content }
              elsif value.content_type == "image_data"
                { type: "input_image", image_url: value.content }
              elsif value.content_type == "file_data"
                { type: "input_file", filename: value.metadata[:filename], file_data: value.content }
              else
                raise ArgumentError, "Unsupported content type in message: #{value.content_type}"
              end
            when Hash
              value
            else
              raise ArgumentError, "Unsupported content in message: #{value}"
            end
          end

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
