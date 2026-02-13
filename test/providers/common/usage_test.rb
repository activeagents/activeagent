# frozen_string_literal: true

require "test_helper"
require "active_agent/providers/common/usage"

module ActiveAgent
  module Providers
    module Common
      class UsageTest < ActiveSupport::TestCase
        test "normalizes OpenAI Chat completion usage" do
          usage_hash = {
            "prompt_tokens" => 100,
            "completion_tokens" => 25,
            "total_tokens" => 125,
            "prompt_tokens_details" => { "cached_tokens" => 20 },
            "completion_tokens_details" => { "reasoning_tokens" => 3, "audio_tokens" => 5 }
          }

          usage = Usage.from_openai_chat(usage_hash)

          assert_equal 100, usage.input_tokens
          assert_equal 25, usage.output_tokens
          assert_equal 125, usage.total_tokens
          assert_equal 20, usage.cached_tokens
          assert_equal 3, usage.reasoning_tokens
          assert_equal 5, usage.audio_tokens
        end

        test "normalizes OpenAI Embedding usage with no output tokens" do
          usage_hash = {
            "prompt_tokens" => 8,
            "total_tokens" => 8
          }

          usage = Usage.from_openai_embedding(usage_hash)

          assert_equal 8, usage.input_tokens
          assert_equal 0, usage.output_tokens
          assert_equal 8, usage.total_tokens
        end

        test "normalizes OpenAI Responses API usage" do
          usage_hash = {
            "input_tokens" => 150,
            "output_tokens" => 75,
            "total_tokens" => 225,
            "input_tokens_details" => { "cached_tokens" => 50 },
            "output_tokens_details" => { "reasoning_tokens" => 10 }
          }

          usage = Usage.from_openai_responses(usage_hash)

          assert_equal 150, usage.input_tokens
          assert_equal 75, usage.output_tokens
          assert_equal 225, usage.total_tokens
          assert_equal 50, usage.cached_tokens
          assert_equal 10, usage.reasoning_tokens
        end

        test "normalizes Anthropic usage and calculates total_tokens" do
          usage_hash = {
            "input_tokens" => 2095,
            "output_tokens" => 503,
            "cache_read_input_tokens" => 1500,
            "cache_creation_input_tokens" => 2051,
            "service_tier" => "standard"
          }

          usage = Usage.from_anthropic(usage_hash)

          assert_equal 2095, usage.input_tokens
          assert_equal 503, usage.output_tokens
          assert_equal 2598, usage.total_tokens # Calculated
          assert_equal 1500, usage.cached_tokens
          assert_equal 2051, usage.cache_creation_tokens
          assert_equal "standard", usage.service_tier
        end

        test "normalizes Ollama usage and converts nanoseconds to milliseconds" do
          usage_hash = {
            "prompt_eval_count" => 50,
            "eval_count" => 25,
            "total_duration" => 5_000_000_000,
            "load_duration" => 1_000_000_000,
            "prompt_eval_duration" => 500_000_000,
            "eval_duration" => 2_000_000_000
          }

          usage = Usage.from_ollama(usage_hash)

          assert_equal 50, usage.input_tokens
          assert_equal 25, usage.output_tokens
          assert_equal 75, usage.total_tokens # Calculated
          assert_equal 5000, usage.duration_ms
          assert_equal 1000, usage.provider_details[:load_duration_ms]
          assert_equal 500, usage.provider_details[:prompt_eval_duration_ms]
          assert_equal 2000, usage.provider_details[:eval_duration_ms]
          assert_equal 12.5, usage.provider_details[:tokens_per_second]
        end

        test "normalizes OpenRouter usage (same as OpenAI Chat)" do
          usage_hash = {
            "prompt_tokens" => 14,
            "completion_tokens" => 4,
            "total_tokens" => 18
          }

          usage = Usage.from_openrouter(usage_hash)

          assert_equal 14, usage.input_tokens
          assert_equal 4, usage.output_tokens
          assert_equal 18, usage.total_tokens
        end

        test "auto-detects provider format for OpenAI Chat" do
          usage_hash = {
            "prompt_tokens" => 100,
            "completion_tokens" => 25,
            "total_tokens" => 125
          }

          usage = Usage.from_provider_usage(usage_hash)

          assert_equal 100, usage.input_tokens
          assert_equal 25, usage.output_tokens
          assert_equal 125, usage.total_tokens
        end

        test "auto-detects provider format for Anthropic" do
          usage_hash = {
            "input_tokens" => 2095,
            "output_tokens" => 503,
            "service_tier" => "standard"
          }

          usage = Usage.from_provider_usage(usage_hash)

          assert_equal 2095, usage.input_tokens
          assert_equal 503, usage.output_tokens
          assert_equal 2598, usage.total_tokens
        end

        test "auto-detects provider format for Ollama" do
          usage_hash = {
            "prompt_eval_count" => 50,
            "eval_count" => 25,
            "total_duration" => 5_000_000_000
          }

          usage = Usage.from_provider_usage(usage_hash)

          assert_equal 50, usage.input_tokens
          assert_equal 25, usage.output_tokens
          assert_equal 75, usage.total_tokens
        end

        test "auto-detects provider format for OpenAI Responses API" do
          usage_hash = {
            "input_tokens" => 150,
            "output_tokens" => 75,
            "total_tokens" => 225,
            "input_tokens_details" => { "cached_tokens" => 50 }
          }

          usage = Usage.from_provider_usage(usage_hash)

          assert_equal 150, usage.input_tokens
          assert_equal 75, usage.output_tokens
          assert_equal 225, usage.total_tokens
        end

        test "auto-detects provider format for OpenAI Embeddings" do
          usage_hash = {
            "prompt_tokens" => 8,
            "total_tokens" => 8
          }

          usage = Usage.from_provider_usage(usage_hash)

          assert_equal 8, usage.input_tokens
          assert_equal 0, usage.output_tokens
          assert_equal 8, usage.total_tokens
        end

        test "calculates total_tokens if not provided" do
          usage = Usage.new(input_tokens: 100, output_tokens: 25)

          assert_equal 125, usage.total_tokens
        end

        test "works with symbol keys" do
          usage_hash = {
            prompt_tokens: 100,
            completion_tokens: 25,
            total_tokens: 125
          }

          usage = Usage.from_openai_chat(usage_hash)

          assert_equal 100, usage.input_tokens
          assert_equal 25, usage.output_tokens
          assert_equal 125, usage.total_tokens
        end

        test "returns nil for nil input" do
          assert_nil Usage.from_openai_chat(nil)
          assert_nil Usage.from_anthropic(nil)
          assert_nil Usage.from_ollama(nil)
          assert_nil Usage.from_provider_usage(nil)
        end

        test "handles missing optional fields gracefully" do
          usage_hash = {
            "prompt_tokens" => 100,
            "completion_tokens" => 25,
            "total_tokens" => 125
          }

          usage = Usage.from_openai_chat(usage_hash)

          assert_nil usage.cached_tokens
          assert_nil usage.reasoning_tokens
          assert_nil usage.audio_tokens
        end

        test "preserves provider-specific details" do
          usage_hash = {
            "input_tokens" => 2095,
            "output_tokens" => 503,
            "cache_creation" => {
              "ephemeral_5m_input_tokens" => 1000,
              "ephemeral_1h_input_tokens" => 500
            },
            "server_tool_use" => {
              "web_fetch_requests" => 2,
              "web_search_requests" => 1
            }
          }

          usage = Usage.from_anthropic(usage_hash)

          assert_equal 1000, usage.provider_details[:cache_creation][:ephemeral_5m_input_tokens]
          assert_equal 2, usage.provider_details[:server_tool_use][:web_fetch_requests]
        end

        # --- Usage addition (multi-turn accumulation) ---

        test "addition combines two usage objects" do
          usage1 = Usage.new(input_tokens: 100, output_tokens: 50, cached_tokens: 20)
          usage2 = Usage.new(input_tokens: 75, output_tokens: 25, cached_tokens: 10)

          combined = usage1 + usage2

          assert_equal 175, combined.input_tokens
          assert_equal 75, combined.output_tokens
          assert_equal 250, combined.total_tokens
          assert_equal 30, combined.cached_tokens
        end

        test "addition handles nil optional fields" do
          usage1 = Usage.new(input_tokens: 100, output_tokens: 50)
          usage2 = Usage.new(input_tokens: 75, output_tokens: 25, reasoning_tokens: 10)

          combined = usage1 + usage2

          assert_equal 175, combined.input_tokens
          assert_equal 75, combined.output_tokens
          assert_equal 10, combined.reasoning_tokens
          assert_nil combined.cached_tokens
        end

        test "addition with nil returns self" do
          usage = Usage.new(input_tokens: 100, output_tokens: 50)

          combined = usage + nil

          assert_equal 100, combined.input_tokens
          assert_equal 50, combined.output_tokens
        end

        test "chained addition accumulates across multiple turns" do
          turn1 = Usage.new(input_tokens: 50, output_tokens: 20)
          turn2 = Usage.new(input_tokens: 80, output_tokens: 30, cached_tokens: 10)
          turn3 = Usage.new(input_tokens: 60, output_tokens: 25, cached_tokens: 5)

          cumulative = turn1 + turn2 + turn3

          assert_equal 190, cumulative.input_tokens
          assert_equal 75, cumulative.output_tokens
          assert_equal 265, cumulative.total_tokens
          assert_equal 15, cumulative.cached_tokens
        end
      end
    end
  end
end
