# frozen_string_literal: true

require "test_helper"

require_relative "../../../../lib/active_agent/providers/ollama/embedding/transforms"

module Providers
  module Ollama
    module Embedding
      class TransformsTest < ActiveSupport::TestCase
        private

        def transforms
          ActiveAgent::Providers::Ollama::Embedding::Transforms
        end

        # gem_to_hash tests
        test "gem_to_hash converts object with to_json to hash with symbols" do
          obj = Object.new
          def obj.to_json
            '{"input":"hello","model":"llama2"}'
          end

          result = transforms.gem_to_hash(obj)

          assert_equal({ input: "hello", model: "llama2" }, result)
        end

        test "gem_to_hash returns object as-is if doesn't support to_json" do
          obj = 123

          result = transforms.gem_to_hash(obj)

          assert_equal 123, result
        end

        # normalize_params tests
        test "normalize_params extracts Ollama-specific params" do
          params = {
            input: "hello world",
            model: "llama2",
            options: { temperature: 0.7 },
            keep_alive: "5m",
            truncate: true
          }

          openai_params, ollama_params = transforms.normalize_params(params)

          assert_equal({ temperature: 0.7 }, ollama_params[:options])
          assert_equal "5m", ollama_params[:keep_alive]
          assert_equal true, ollama_params[:truncate]
          refute openai_params.key?(:options)
        end

        test "normalize_params extracts option attributes from top level" do
          params = {
            input: "hello",
            model: "llama2",
            temperature: 0.8,
            top_p: 0.9,
            seed: 42
          }

          openai_params, ollama_params = transforms.normalize_params(params)

          assert_equal 0.8, ollama_params[:options][:temperature]
          assert_equal 0.9, ollama_params[:options][:top_p]
          assert_equal 42, ollama_params[:options][:seed]
          refute openai_params.key?(:temperature)
        end

        test "normalize_params normalizes input" do
          params = { input: "hello world", model: "llama2" }

          openai_params, _ollama_params = transforms.normalize_params(params)

          assert_equal [ "hello world" ], openai_params[:input]
        end

        # normalize_input tests
        test "normalize_input converts string to array" do
          input = "hello world"

          result = transforms.normalize_input(input)

          assert_equal [ "hello world" ], result
        end

        test "normalize_input keeps array of strings" do
          input = [ "hello", "world", "test" ]

          result = transforms.normalize_input(input)

          assert_equal [ "hello", "world", "test" ], result
        end

        test "normalize_input raises error for non-string array" do
          input = [ "hello", 123, "world" ]

          error = assert_raises(ArgumentError) do
            transforms.normalize_input(input)
          end

          assert_includes error.message, "must contain only strings"
        end

        test "normalize_input raises error for empty strings" do
          input = [ "hello", "", "world" ]

          error = assert_raises(ArgumentError) do
            transforms.normalize_input(input)
          end

          assert_includes error.message, "cannot contain empty strings"
        end

        test "normalize_input returns nil for nil" do
          result = transforms.normalize_input(nil)

          assert_nil result
        end

        test "normalize_input raises error for invalid types" do
          input = { custom: "format" }

          error = assert_raises(ArgumentError) do
            transforms.normalize_input(input)
          end

          assert_includes error.message, "Cannot normalize"
        end

        # serialize_input tests
        test "serialize_input returns string for single element" do
          input = [ "hello" ]

          result = transforms.serialize_input(input)

          assert_equal "hello", result
        end

        test "serialize_input keeps array for multiple elements" do
          input = [ "hello", "world" ]

          result = transforms.serialize_input(input)

          assert_equal [ "hello", "world" ], result
        end

        test "serialize_input returns nil for nil" do
          result = transforms.serialize_input(nil)

          assert_nil result
        end

        # cleanup_serialized_request tests
        test "cleanup_serialized_request merges and serializes" do
          openai_hash = { input: [ "hello" ], model: "llama2" }
          ollama_params = { options: { temperature: 0.8 }, keep_alive: "5m" }

          result = transforms.cleanup_serialized_request(openai_hash, ollama_params, {})

          assert_equal "hello", result[:input]
          assert_equal({ temperature: 0.8 }, result[:options])
          assert_equal "5m", result[:keep_alive]
        end

        test "cleanup_serialized_request skips defaults" do
          openai_hash = { input: [ "hello" ], model: "llama2" }
          ollama_params = { keep_alive: "5m", truncate: true }
          defaults = { keep_alive: "5m" }

          result = transforms.cleanup_serialized_request(openai_hash, ollama_params, defaults)

          assert_nil result[:keep_alive]
          assert_equal true, result[:truncate]
        end

        test "cleanup_serialized_request skips empty ollama params" do
          openai_hash = { input: [ "hello" ], model: "llama2" }
          ollama_params = { options: {}, keep_alive: nil }

          result = transforms.cleanup_serialized_request(openai_hash, ollama_params, {})

          assert_nil result[:options]
          assert_nil result[:keep_alive]
        end

        test "cleanup_serialized_request serializes options object" do
          options_obj = Object.new
          def options_obj.respond_to?(method)
            method == :serialize || super
          end
          def options_obj.serialize
            { temperature: 0.7 }
          end

          openai_hash = { input: [ "hello" ], model: "llama2" }
          ollama_params = { options: options_obj }

          result = transforms.cleanup_serialized_request(openai_hash, ollama_params, {})

          assert_equal({ temperature: 0.7 }, result[:options])
        end

        # Integration tests
        test "integration full params normalization with options" do
          params = {
            input: [ "first", "second", "third" ],
            model: "llama2",
            temperature: 0.7,
            top_p: 0.9,
            keep_alive: "10m"
          }

          openai_params, ollama_params = transforms.normalize_params(params)

          assert_equal [ "first", "second", "third" ], openai_params[:input]
          assert_equal 0.7, ollama_params[:options][:temperature]
          assert_equal 0.9, ollama_params[:options][:top_p]
          assert_equal "10m", ollama_params[:keep_alive]
        end

        test "integration round-trip normalization and serialization" do
          params = {
            input: "single text",
            model: "llama2",
            temperature: 0.8
          }

          openai_params, ollama_params = transforms.normalize_params(params)
          result = transforms.cleanup_serialized_request(openai_params, ollama_params, {})

          assert_equal "single text", result[:input]
          assert_equal "llama2", result[:model]
          assert_equal 0.8, result[:options][:temperature]
        end

        test "integration multi-input normalization and serialization" do
          params = {
            input: [ "first", "second", "third" ],
            model: "llama2",
            options: { num_ctx: 2048 }
          }

          openai_params, ollama_params = transforms.normalize_params(params)
          result = transforms.cleanup_serialized_request(openai_params, ollama_params, {})

          assert_equal [ "first", "second", "third" ], result[:input]
          assert_equal({ num_ctx: 2048 }, result[:options])
        end
      end
    end
  end
end
