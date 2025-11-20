# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module Common
      # Normalizes token usage statistics across AI providers.
      #
      # Providers return usage data in different formats with different field names.
      # This model normalizes them into a consistent structure, automatically calculating
      # +total_tokens+ if not provided.
      #
      # @example Accessing normalized usage data
      #   usage = response.normalized_usage
      #   usage.input_tokens      #=> 100
      #   usage.output_tokens     #=> 25
      #   usage.total_tokens      #=> 125
      #   usage.cached_tokens     #=> 20 (if available)
      #
      # @example Provider-specific details
      #   usage.provider_details  #=> { "completion_tokens_details" => {...}, ... }
      #   usage.duration_ms       #=> 5000 (for Ollama)
      #   usage.service_tier      #=> "standard" (for Anthropic)
      #
      # @see https://platform.openai.com/docs/api-reference/chat/object OpenAI Chat Completion
      # @see https://docs.anthropic.com/en/api/messages Anthropic Messages API
      # @see https://github.com/ollama/ollama/blob/main/docs/api.md Ollama API
      class Usage < BaseModel
        # @!attribute [rw] input_tokens
        #   Normalized from:
        #   - OpenAI Chat/Embeddings: prompt_tokens
        #   - OpenAI Responses API: input_tokens
        #   - Anthropic: input_tokens
        #   - Ollama: prompt_eval_count
        #   - OpenRouter: prompt_tokens
        #
        #   @return [Integer]
        attribute :input_tokens, :integer, default: 0

        # @!attribute [rw] output_tokens
        #   Normalized from:
        #   - OpenAI Chat: completion_tokens
        #   - OpenAI Responses API: output_tokens
        #   - Anthropic: output_tokens
        #   - Ollama: eval_count
        #   - OpenRouter: completion_tokens
        #   - OpenAI Embeddings: 0 (no output tokens)
        #
        #   @return [Integer]
        attribute :output_tokens, :integer, default: 0

        # @!attribute [rw] total_tokens
        #   Automatically calculated as input_tokens + output_tokens if not provided by provider.
        #
        #   @return [Integer]
        attribute :total_tokens, :integer

        # @!attribute [rw] cached_tokens
        #   Available from:
        #   - OpenAI: prompt_tokens_details.cached_tokens or input_tokens_details.cached_tokens
        #   - Anthropic: cache_read_input_tokens
        #
        #   @return [Integer, nil]
        attribute :cached_tokens, :integer

        # @!attribute [rw] reasoning_tokens
        #   Available from:
        #   - OpenAI Chat: completion_tokens_details.reasoning_tokens
        #   - OpenAI Responses: output_tokens_details.reasoning_tokens
        #
        #   @return [Integer, nil]
        attribute :reasoning_tokens, :integer

        # @!attribute [rw] audio_tokens
        #   Available from:
        #   - OpenAI: sum of prompt_tokens_details.audio_tokens and completion_tokens_details.audio_tokens
        #
        #   @return [Integer, nil]
        attribute :audio_tokens, :integer

        # @!attribute [rw] cache_creation_tokens
        #   Available from:
        #   - Anthropic: cache_creation_input_tokens
        #
        #   @return [Integer, nil]
        attribute :cache_creation_tokens, :integer

        # @!attribute [rw] service_tier
        #   Available from:
        #   - Anthropic: service_tier ("standard", "priority", "batch")
        #
        #   @return [String, nil]
        attribute :service_tier, :string

        # @!attribute [rw] duration_ms
        #   Available from:
        #   - Ollama: total_duration (converted from nanoseconds)
        #
        #   @return [Integer, nil]
        attribute :duration_ms, :integer

        # @!attribute [rw] provider_details
        #   Preserves provider-specific information that doesn't fit the normalized structure.
        #   Useful for debugging or provider-specific features.
        #
        #   @return [Hash]
        attribute :provider_details, default: -> { {} }

        # Automatically calculates total_tokens if not provided.
        #
        # @param attributes [Hash]
        # @option attributes [Integer] :input_tokens
        # @option attributes [Integer] :output_tokens
        # @option attributes [Integer] :total_tokens (calculated if not provided)
        # @option attributes [Integer] :cached_tokens
        # @option attributes [Integer] :reasoning_tokens
        # @option attributes [Integer] :audio_tokens
        # @option attributes [Integer] :cache_creation_tokens
        # @option attributes [String] :service_tier
        # @option attributes [Integer] :duration_ms
        # @option attributes [Hash] :provider_details
        def initialize(attributes = {})
          super
          # Calculate total_tokens if not provided
          self.total_tokens ||= (input_tokens || 0) + (output_tokens || 0)
        end

        # Sums all token counts from two Usage objects.
        #
        # @param other [Usage]
        # @return [Usage]
        #
        # @example
        #   usage1 = Usage.new(input_tokens: 100, output_tokens: 50)
        #   usage2 = Usage.new(input_tokens: 75, output_tokens: 25)
        #   combined = usage1 + usage2
        #   combined.input_tokens  #=> 175
        #   combined.output_tokens #=> 75
        #   combined.total_tokens  #=> 250
        def +(other)
          return self unless other

          self.class.new(
            input_tokens:          self.input_tokens  + other.input_tokens,
            output_tokens:         self.output_tokens + other.output_tokens,
            total_tokens:          self.total_tokens  + other.total_tokens,
            cached_tokens:         sum_optional(self.cached_tokens,         other.cached_tokens),
            cache_creation_tokens: sum_optional(self.cache_creation_tokens, other.cache_creation_tokens),
            reasoning_tokens:      sum_optional(self.reasoning_tokens,      other.reasoning_tokens),
            audio_tokens:          sum_optional(self.audio_tokens,          other.audio_tokens)
          )
        end

        # Creates a Usage object from OpenAI Chat Completion usage data.
        #
        # @param usage_hash [Hash]
        # @return [Usage]
        #
        # @example
        #   Usage.from_openai_chat({
        #     "prompt_tokens" => 100,
        #     "completion_tokens" => 25,
        #     "total_tokens" => 125,
        #     "prompt_tokens_details" => { "cached_tokens" => 20 },
        #     "completion_tokens_details" => { "reasoning_tokens" => 3 }
        #   })
        def self.from_openai_chat(usage_hash)
          return nil unless usage_hash

          usage = usage_hash.deep_symbolize_keys
          prompt_details = usage[:prompt_tokens_details] || {}
          completion_details = usage[:completion_tokens_details] || {}

          audio_sum = [
            prompt_details[:audio_tokens],
            completion_details[:audio_tokens]
          ].compact.sum

          new(
            **usage.slice(:total_tokens),
            input_tokens: usage[:prompt_tokens] || 0,
            output_tokens: usage[:completion_tokens] || 0,
            cached_tokens: prompt_details[:cached_tokens],
            reasoning_tokens: completion_details[:reasoning_tokens],
            audio_tokens: audio_sum > 0 ? audio_sum : nil,
            provider_details: usage.slice(:prompt_tokens_details, :completion_tokens_details).compact
          )
        end

        # Creates a Usage object from OpenAI Embedding API usage data.
        #
        # @param usage_hash [Hash]
        # @return [Usage]
        #
        # @example
        #   Usage.from_openai_embedding({
        #     "prompt_tokens" => 8,
        #     "total_tokens" => 8
        #   })
        def self.from_openai_embedding(usage_hash)
          return nil unless usage_hash

          usage = usage_hash.deep_symbolize_keys

          new(
            **usage.slice(:total_tokens),
            input_tokens: usage[:prompt_tokens] || 0,
            output_tokens: 0, # Embeddings don't generate output tokens
            provider_details: usage.except(:prompt_tokens, :total_tokens)
          )
        end

        # Creates a Usage object from OpenAI Responses API usage data.
        #
        # @param usage_hash [Hash]
        # @return [Usage]
        #
        # @example
        #   Usage.from_openai_responses({
        #     "input_tokens" => 150,
        #     "output_tokens" => 75,
        #     "total_tokens" => 225,
        #     "input_tokens_details" => { "cached_tokens" => 50 },
        #     "output_tokens_details" => { "reasoning_tokens" => 10 }
        #   })
        def self.from_openai_responses(usage_hash)
          return nil unless usage_hash

          usage = usage_hash.deep_symbolize_keys
          input_details = usage[:input_tokens_details] || {}
          output_details = usage[:output_tokens_details] || {}

          new(
            **usage.slice(:input_tokens, :output_tokens, :total_tokens),
            input_tokens: usage[:input_tokens] || 0,
            output_tokens: usage[:output_tokens] || 0,
            cached_tokens: input_details[:cached_tokens],
            reasoning_tokens: output_details[:reasoning_tokens],
            provider_details: usage.slice(:input_tokens_details, :output_tokens_details).compact
          )
        end

        # Creates a Usage object from Anthropic usage data.
        #
        # @param usage_hash [Hash]
        # @return [Usage]
        #
        # @example
        #   Usage.from_anthropic({
        #     "input_tokens" => 2095,
        #     "output_tokens" => 503,
        #     "cache_read_input_tokens" => 1500,
        #     "cache_creation_input_tokens" => 2051,
        #     "service_tier" => "standard"
        #   })
        def self.from_anthropic(usage_hash)
          return nil unless usage_hash

          usage = usage_hash.deep_symbolize_keys

          new(
            **usage.slice(:input_tokens, :output_tokens, :service_tier),
            input_tokens: usage[:input_tokens] || 0,
            output_tokens: usage[:output_tokens] || 0,
            cached_tokens: usage[:cache_read_input_tokens],
            cache_creation_tokens: usage[:cache_creation_input_tokens],
            provider_details: usage.slice(:cache_creation, :server_tool_use).compact
          )
        end

        # Creates a Usage object from Ollama usage data.
        #
        # @param usage_hash [Hash]
        # @return [Usage]
        #
        # @example
        #   Usage.from_ollama({
        #     "prompt_eval_count" => 50,
        #     "eval_count" => 25,
        #     "total_duration" => 5000000000,
        #     "load_duration" => 1000000000
        #   })
        def self.from_ollama(usage_hash)
          return nil unless usage_hash

          usage = usage_hash.deep_symbolize_keys

          new(
            input_tokens: usage[:prompt_eval_count] || 0,
            output_tokens: usage[:eval_count] || 0,
            duration_ms: convert_nanoseconds_to_ms(usage[:total_duration]),
            provider_details: {
              load_duration_ms: convert_nanoseconds_to_ms(usage[:load_duration]),
              prompt_eval_duration_ms: convert_nanoseconds_to_ms(usage[:prompt_eval_duration]),
              eval_duration_ms: convert_nanoseconds_to_ms(usage[:eval_duration]),
              tokens_per_second: calculate_tokens_per_second(usage[:eval_count], usage[:eval_duration])
            }.compact
          )
        end

        # Creates a Usage object from OpenRouter usage data.
        #
        # OpenRouter uses the same format as OpenAI Chat Completion.
        #
        # @param usage_hash [Hash]
        # @return [Usage]
        #
        # @example
        #   Usage.from_openrouter({
        #     "prompt_tokens" => 14,
        #     "completion_tokens" => 4,
        #     "total_tokens" => 18
        #   })
        def self.from_openrouter(usage_hash)
          from_openai_chat(usage_hash)
        end

        # Auto-detects the provider format and creates a normalized Usage object.
        #
        # @note Detection is based on hash structure rather than native gem types
        #   because we cannot force-load all provider gems. This allows the framework
        #   to work with only the gems the user has installed.
        #
        # @param usage_hash [Hash]
        # @return [Usage, nil]
        #
        # @example
        #   Usage.from_provider_usage(some_usage_hash)
        def self.from_provider_usage(usage_hash)
          return nil unless usage_hash.is_a?(Hash)

          usage = usage_hash.deep_symbolize_keys

          # Detect Ollama by presence of nanosecond duration fields
          if usage.key?(:total_duration)
            from_ollama(usage_hash)
          # Detect Anthropic by presence of cache_creation or service_tier
          elsif usage.key?(:cache_creation) || usage.key?(:service_tier)
            from_anthropic(usage_hash)
          # Detect OpenAI Responses API by input_tokens/output_tokens with details
          elsif usage.key?(:input_tokens) && usage.key?(:input_tokens_details)
            from_openai_responses(usage_hash)
          # Detect OpenAI Chat/OpenRouter by prompt_tokens/completion_tokens
          elsif usage.key?(:completion_tokens)
            from_openai_chat(usage_hash)
          # Detect OpenAI Embedding by prompt_tokens without completion_tokens
          elsif usage.key?(:prompt_tokens)
            from_openai_embedding(usage_hash)
          # Default to raw initialization
          else
            new(usage_hash)
          end
        end

        private

        # @param a [Integer, nil]
        # @param b [Integer, nil]
        # @return [Integer, nil] nil if both inputs are nil
        def sum_optional(a, b)
          return nil if a.nil? && b.nil?
          (a || 0) + (b || 0)
        end

        # @param nanoseconds [Integer, nil]
        # @return [Integer, nil]
        def self.convert_nanoseconds_to_ms(nanoseconds)
          return nil unless nanoseconds

          (nanoseconds / 1_000_000.0).round
        end

        # @param tokens [Integer, nil]
        # @param duration_ns [Integer, nil]
        # @return [Float, nil]
        def self.calculate_tokens_per_second(tokens, duration_ns)
          return nil unless tokens && duration_ns && duration_ns > 0

          (tokens.to_f / (duration_ns / 1_000_000_000.0)).round(2)
        end
      end
    end
  end
end
