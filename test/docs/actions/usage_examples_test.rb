# frozen_string_literal: true

require "test_helper"

module Docs
  module Actions
    module Usage
      class BasicUsageAgent < ApplicationAgent
        generate_with :mock

        def chat
          prompt(message: params[:message])
        end
      end

      class UsageExamplesTest < ActiveAgentTestCase
        test "accessing usage statistics" do
          VCR.use_cassette("docs/actions/usage/accessing_usage") do
            response = BasicUsageAgent.with(message: "Hello").chat.generate_now

            # region accessing_usage
            # Normalized fields (available across all providers)
            response.usage.input_tokens
            response.usage.output_tokens
            response.usage.total_tokens
            # endregion accessing_usage

            assert_kind_of Integer, response.usage.input_tokens
            assert_kind_of Integer, response.usage.output_tokens
            assert_kind_of Integer, response.usage.total_tokens
          end
        end

        test "common fields across providers" do
          VCR.use_cassette("docs/actions/usage/common_fields") do
            response = BasicUsageAgent.with(message: "Hello").chat.generate_now

            # region common_fields
            usage = response.usage

            # All providers support these
            usage.input_tokens    # Tokens in the prompt/input
            usage.output_tokens   # Tokens in the completion/output
            usage.total_tokens    # Total tokens used (auto-calculated if not provided)
            # endregion common_fields

            assert usage.input_tokens >= 0
            assert usage.output_tokens >= 0
            assert usage.total_tokens >= 0
          end
        end

        class OpenAIUsageAgent < ApplicationAgent
          generate_with :openai, model: "gpt-4o-mini"

          def chat
            prompt(message: params[:message])
          end
        end

        test "OpenAI provider-specific fields" do
          VCR.use_cassette("docs/actions/usage/provider_specific_openai") do
            response = OpenAIUsageAgent.with(message: "Hello").chat.generate_now

            # region provider_specific_openai
            usage = response.usage

            # OpenAI-specific fields
            usage.cached_tokens      # Prompt tokens served from cache
            usage.reasoning_tokens   # Tokens used for reasoning (o1 models)
            usage.audio_tokens       # Tokens for audio input/output
            # endregion provider_specific_openai

            assert_respond_to usage, :cached_tokens
            assert_respond_to usage, :reasoning_tokens
            assert_respond_to usage, :audio_tokens
          end
        end

        class AnthropicUsageAgent < ApplicationAgent
          generate_with :anthropic, model: "claude-3-5-haiku-20241022"

          def chat
            prompt(message: params[:message])
          end
        end

        test "Anthropic provider-specific fields" do
          VCR.use_cassette("docs/actions/usage/provider_specific_anthropic") do
            response = AnthropicUsageAgent.with(message: "Hello").chat.generate_now

            # region provider_specific_anthropic
            usage = response.usage

            # Anthropic-specific fields
            usage.cached_tokens             # Tokens read from cache
            usage.cache_creation_tokens     # Tokens written to cache
            usage.service_tier              # "standard" or "prioritized"
            # endregion provider_specific_anthropic

            assert_respond_to usage, :cached_tokens
            assert_respond_to usage, :cache_creation_tokens
            assert_respond_to usage, :service_tier
          end
        end

        class OllamaUsageAgent < ApplicationAgent
          generate_with :ollama, model: "llama3.2"

          def chat
            prompt(message: params[:message])
          end
        end

        test "Ollama provider-specific fields" do
          skip "Requires local Ollama server"

          response = OllamaUsageAgent.with(message: "Hello").chat.generate_now

          # region provider_specific_ollama
          usage = response.usage

          # Ollama-specific fields
          usage.duration_ms                             # Total request duration in ms
          usage.provider_details[:tokens_per_second]    # Generation throughput
          # endregion provider_specific_ollama

          assert usage.duration_ms > 0
          assert usage.provider_details[:tokens_per_second] > 0
        end

        test "OpenAI provider details" do
          VCR.use_cassette("docs/actions/usage/provider_details_openai") do
            response = OpenAIUsageAgent.with(message: "Hello").chat.generate_now

            # region provider_details_openai
            usage = response.usage

            # Access raw provider-specific data
            usage.provider_details
            # Contains: prompt_tokens_details, completion_tokens_details, etc.
            # endregion provider_details_openai

            assert usage.provider_details.is_a?(Hash)
          end
        end

        test "Ollama timing breakdown" do
          skip "Requires local Ollama server"

          response = OllamaUsageAgent.with(message: "Hello").chat.generate_now

          # region provider_details_ollama
          usage = response.usage

          # Ollama provides detailed timing metrics
          usage.provider_details[:load_duration_ms]         # Model load time
          usage.provider_details[:prompt_eval_duration_ms]  # Prompt processing time
          usage.provider_details[:eval_duration_ms]         # Generation time
          # endregion provider_details_ollama

          assert usage.provider_details[:load_duration_ms]
          assert usage.provider_details[:prompt_eval_duration_ms]
          assert usage.provider_details[:eval_duration_ms]
        end

        test "cost tracking calculation" do
          VCR.use_cassette("docs/actions/usage/cost_tracking") do
            response = BasicUsageAgent.with(message: "Analyze this data").chat.generate_now

            # region cost_tracking
            INPUT_PRICE_PER_TOKEN = 0.00001
            OUTPUT_PRICE_PER_TOKEN = 0.00003
            CACHE_DISCOUNT_PER_TOKEN = 0.000005

            # Track usage per request
            input_cost = response.usage.input_tokens * INPUT_PRICE_PER_TOKEN
            output_cost = response.usage.output_tokens * OUTPUT_PRICE_PER_TOKEN
            total_cost = input_cost + output_cost

            # Account for cached tokens (reduced cost)
            if response.usage.cached_tokens
              cache_savings = response.usage.cached_tokens * CACHE_DISCOUNT_PER_TOKEN
              total_cost -= cache_savings
            end
            # endregion cost_tracking

            assert total_cost > 0
            assert input_cost >= 0
            assert output_cost >= 0
          end
        end

        test "embeddings have zero output tokens" do
          VCR.use_cassette("docs/actions/usage/embeddings_usage") do
            response = BasicUsageAgent.embed(input: "Search text").embed_now

            # region embeddings_usage
            # Embeddings only consume input tokens
            response.usage.input_tokens   # Text vectorized
            response.usage.output_tokens  # Always 0 for embeddings
            response.usage.total_tokens   # Same as input_tokens
            # endregion embeddings_usage

            assert response.usage.input_tokens > 0
            assert_equal 0, response.usage.output_tokens
            assert response.usage.total_tokens > 0
          end
        end
      end
    end
  end
end
