# frozen_string_literal: true

require "test_helper"
require "ostruct"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping OpenAI Embedding transforms tests"
  return
end

require_relative "../../../../lib/active_agent/providers/open_ai/embedding/transforms"

module Providers
  module OpenAI
    module Embedding
      class TransformsTest < ActiveSupport::TestCase
        private

        def transforms
          ActiveAgent::Providers::OpenAI::Embedding::Transforms
        end

        # gem_to_hash tests
        test "gem_to_hash converts object with to_json to hash" do
          obj = Object.new
          def obj.to_json
            '{"input":"hello","model":"text-embedding-ada-002"}'
          end

          result =  transforms.gem_to_hash(obj)

          assert_equal({ "input" => "hello", "model" => "text-embedding-ada-002" }, result)
        end

        test "gem_to_hash returns object as-is if it doesn't support to_json" do
          obj = 123

          result =  transforms.gem_to_hash(obj)

          assert_equal 123, result
        end

        # normalize_params tests
        test "normalize_params normalizes input when present" do
          params = { input: "hello world", model: "text-embedding-ada-002" }

          result =  transforms.normalize_params(params)

          assert_equal "hello world", result[:input]
          assert_equal "text-embedding-ada-002", result[:model]
        end

        test "normalize_params handles array input" do
          params = { input: [ "hello", "world" ], model: "text-embedding-ada-002" }

          result =  transforms.normalize_params(params)

          assert_equal [ "hello", "world" ], result[:input]
        end

        test "normalize_params does not modify original params" do
          params = { input: "hello", model: "test" }
          original = params.dup

           transforms.normalize_params(params)

          assert_equal original, params
        end

        test "normalize_params handles params without input" do
          params = { model: "text-embedding-ada-002" }

          result =  transforms.normalize_params(params)

          assert_equal "text-embedding-ada-002", result[:model]
          assert_nil result[:input]
        end

        # normalize_input tests
        test "normalize_input keeps string unchanged" do
          input = "hello world"

          result =  transforms.normalize_input(input)

          assert_equal "hello world", result
        end

        test "normalize_input keeps array of strings unchanged" do
          input = [ "hello", "world", "test" ]

          result =  transforms.normalize_input(input)

          assert_equal [ "hello", "world", "test" ], result
        end

        test "normalize_input keeps empty array unchanged" do
          input = []

          result =  transforms.normalize_input(input)

          assert_equal [], result
        end

        test "normalize_input keeps token array unchanged" do
          input = [ 1, 2, 3, 4, 5 ]

          result =  transforms.normalize_input(input)

          assert_equal [ 1, 2, 3, 4, 5 ], result
        end

        test "normalize_input keeps array of token arrays unchanged" do
          input = [ [ 1, 2, 3 ], [ 4, 5, 6 ], [ 7, 8, 9 ] ]

          result =  transforms.normalize_input(input)

          assert_equal [ [ 1, 2, 3 ], [ 4, 5, 6 ], [ 7, 8, 9 ] ], result
        end

        test "normalize_input passes through other types" do
          input = { custom: "format" }

          result =  transforms.normalize_input(input)

          assert_equal({ custom: "format" }, result)
        end

        # cleanup_serialized_request tests
        test "cleanup_serialized_request removes nil values" do
          serialized = { input: "hello", model: "test", encoding_format: nil }

          result =  transforms.cleanup_serialized_request(serialized)

          assert_equal "hello", result[:input]
          assert_equal "test", result[:model]
          assert_nil result[:encoding_format]
        end

        test "cleanup_serialized_request removes default values" do
          serialized = { input: "hello", model: "test", encoding_format: "float" }
          defaults = { encoding_format: "float" }

          result =  transforms.cleanup_serialized_request(serialized, defaults)

          assert_equal "hello", result[:input]
          assert_equal "test", result[:model]
          assert_nil result[:encoding_format]
        end

        test "cleanup_serialized_request keeps non-default values" do
          serialized = { input: "hello", model: "test", encoding_format: "base64", dimensions: 256 }
          defaults = { encoding_format: "float", dimensions: 1536 }

          result =  transforms.cleanup_serialized_request(serialized, defaults)

          assert_equal "hello", result[:input]
          assert_equal "test", result[:model]
          assert_equal "base64", result[:encoding_format]
          assert_equal 256, result[:dimensions]
        end

        test "cleanup_serialized_request handles empty defaults" do
          serialized = { input: "hello", model: "test" }

          result =  transforms.cleanup_serialized_request(serialized, {})

          assert_equal "hello", result[:input]
          assert_equal "test", result[:model]
        end

        # Integration tests
        test "full params normalization with string input" do
          params = {
            input: "The quick brown fox",
            model: "text-embedding-ada-002",
            encoding_format: "float"
          }

          result =  transforms.normalize_params(params)

          assert_equal "The quick brown fox", result[:input]
          assert_equal "text-embedding-ada-002", result[:model]
          assert_equal "float", result[:encoding_format]
        end

        test "full params normalization with array input" do
          params = {
            input: [ "first text", "second text", "third text" ],
            model: "text-embedding-3-small",
            dimensions: 512
          }

          result =  transforms.normalize_params(params)

          assert_equal [ "first text", "second text", "third text" ], result[:input]
          assert_equal "text-embedding-3-small", result[:model]
          assert_equal 512, result[:dimensions]
        end

        test "full params normalization with token array input" do
          params = {
            input: [ 123, 456, 789 ],
            model: "text-embedding-ada-002"
          }

          result =  transforms.normalize_params(params)

          assert_equal [ 123, 456, 789 ], result[:input]
          assert_equal "text-embedding-ada-002", result[:model]
        end

        test "round-trip normalization and cleanup" do
          params = { input: "hello", model: "test", encoding_format: "float" }
          defaults = { encoding_format: "float" }

          normalized =  transforms.normalize_params(params)
          cleaned =  transforms.cleanup_serialized_request(normalized, defaults)

          assert_equal "hello", cleaned[:input]
          assert_equal "test", cleaned[:model]
          assert_nil cleaned[:encoding_format]
        end
      end
    end
  end
end
