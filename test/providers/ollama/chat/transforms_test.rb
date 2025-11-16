# frozen_string_literal: true

require "test_helper"
require "ostruct"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping Ollama Chat transforms tests"
  return
end

require_relative "../../../../lib/active_agent/providers/ollama/chat/transforms"

module Providers
  module Ollama
    module Chat
      class TransformsTest < ActiveSupport::TestCase
        private

        def transforms
          ActiveAgent::Providers::Ollama::Chat::Transforms
        end

        # gem_to_hash tests
        test "gem_to_hash delegates to OpenAI transforms" do
          obj = Object.new
          def obj.to_json
            '{"role":"user","content":"hello"}'
          end

          result = transforms.gem_to_hash(obj)

          assert_equal({ role: "user", content: "hello" }, result)
        end

        # normalize_params tests
        test "normalize_params extracts Ollama-specific parameters" do
          params = {
            messages: [ { role: "user", content: "hello" } ],
            format: "json",
            options: { temperature: 0.7 },
            keep_alive: "5m",
            raw: false
          }

          openai_params, ollama_params = transforms.normalize_params(params)

          assert_equal "json", ollama_params[:format]
          assert_equal({ temperature: 0.7 }, ollama_params[:options])
          assert_equal "5m", ollama_params[:keep_alive]
          assert_equal false, ollama_params[:raw]
          refute openai_params.key?(:format)
          refute openai_params.key?(:options)
        end

        test "normalize_params delegates to OpenAI transforms for base params" do
          params = {
            instructions: "You are helpful",
            messages: [ { role: "user", content: "hello" } ]
          }

          openai_params, ollama_params = transforms.normalize_params(params)

          assert_equal 2, openai_params[:messages].size
          assert_equal :developer, openai_params[:messages][0].role
          assert_empty ollama_params
        end

        test "normalize_params returns empty ollama_params when no Ollama-specific params" do
          params = {
            messages: [ { role: "user", content: "hello" } ],
            model: "llama2"
          }

          openai_params, ollama_params = transforms.normalize_params(params)

          assert_equal 1, openai_params[:messages].size
          assert_empty ollama_params
        end

        # normalize_messages tests
        test "normalize_messages returns correct count" do
          messages = [
            { role: "user", content: "hello" },
            { role: "assistant", content: "hi" }
          ]

          result = transforms.normalize_messages(messages)

          assert_equal 2, result.size
        end

        test "normalize_messages creates user message param" do
          messages = [
            { role: "user", content: "hello" }
          ]

          result = transforms.normalize_messages(messages)

          assert_instance_of ::OpenAI::Models::Chat::ChatCompletionUserMessageParam, result[0]
        end

        test "normalize_messages creates assistant message param" do
          messages = [
            { role: "assistant", content: "hi" }
          ]

          result = transforms.normalize_messages(messages)

          assert_instance_of ::OpenAI::Models::Chat::ChatCompletionAssistantMessageParam, result[0]
        end

        # normalize_instructions tests
        test "normalize_instructions creates single message" do
          instructions = [ "First instruction", "Second instruction" ]

          result = transforms.normalize_instructions(instructions)

          assert_equal 1, result.size
        end

        test "normalize_instructions uses developer role" do
          instructions = [ "First instruction", "Second instruction" ]

          result = transforms.normalize_instructions(instructions)

          assert_equal "developer", result[0][:role]
        end

        test "normalize_instructions creates content parts" do
          instructions = [ "First instruction", "Second instruction" ]

          result = transforms.normalize_instructions(instructions)

          assert_equal 2, result[0][:content].size
        end

        # group_same_role_messages tests
        test "group_same_role_messages merges consecutive same-role messages" do
          messages = [
            { role: "user", content: "hello" },
            { role: "user", content: " world" }
          ]

          result = transforms.group_same_role_messages(messages)

          assert_equal 1, result.size
          assert_equal "user", result[0][:role]
          assert_equal "hello world", result[0][:content]
        end

        test "group_same_role_messages keeps different-role messages separate" do
          messages = [
            { role: "user", content: "hello" },
            { role: "assistant", content: "hi there" }
          ]

          result = transforms.group_same_role_messages(messages)

          assert_equal 2, result.size
          assert_equal "user", result[0][:role]
          assert_equal "assistant", result[1][:role]
        end

        test "group_same_role_messages merges array content" do
          messages = [
            { role: "user", content: [ { type: "text", text: "hello" } ] },
            { role: "user", content: [ { type: "text", text: "world" } ] }
          ]

          result = transforms.group_same_role_messages(messages)

          assert_equal 1, result.size
          assert_equal 2, result[0][:content].size
          assert_equal "hello", result[0][:content][0][:text]
          assert_equal "world", result[0][:content][1][:text]
        end

        test "group_same_role_messages handles mixed content types" do
          messages = [
            { role: "user", content: "hello" },
            { role: "user", content: [ { type: "text", text: "world" } ] }
          ]

          result = transforms.group_same_role_messages(messages)

          assert_equal 1, result.size
          assert result[0][:content].is_a?(Array)
          assert_equal 2, result[0][:content].size
        end

        test "group_same_role_messages returns empty array for nil" do
          assert_equal [], transforms.group_same_role_messages(nil)
        end

        test "group_same_role_messages returns empty array for empty array" do
          assert_equal [], transforms.group_same_role_messages([])
        end

        # cleanup_serialized_request tests
        test "cleanup_serialized_request merges ollama params" do
          openai_hash = { messages: [ { role: "user", content: "hello" } ], model: "llama2" }
          ollama_params = { format: "json", options: { temperature: 0.8 } }
          gem_object = OpenStruct.new(data: {})
          def gem_object.instance_variable_get(key)
            @data ||= {}
            key == :@data ? @data : super
          end

          result = transforms.cleanup_serialized_request(openai_hash, ollama_params, {}, gem_object)

          assert_equal "json", result[:format]
          assert_equal({ temperature: 0.8 }, result[:options])
          assert_equal "llama2", result[:model]
        end

        test "cleanup_serialized_request groups same-role messages" do
          openai_hash = {
            messages: [
              { role: "user", content: "hello" },
              { role: "user", content: " world" }
            ]
          }
          gem_object = OpenStruct.new(data: {})
          def gem_object.instance_variable_get(key)
            @data ||= {}
            key == :@data ? @data : super
          end

          result = transforms.cleanup_serialized_request(openai_hash, {}, {}, gem_object)

          assert_equal 1, result[:messages].size
          assert_equal "hello world", result[:messages][0][:content]
        end

        test "cleanup_serialized_request skips nil and empty ollama params" do
          openai_hash = { messages: [], model: "llama2" }
          ollama_params = { format: nil, options: {}, keep_alive: "5m" }
          gem_object = OpenStruct.new(data: {})
          def gem_object.instance_variable_get(key)
            @data ||= {}
            key == :@data ? @data : super
          end

          result = transforms.cleanup_serialized_request(openai_hash, ollama_params, {}, gem_object)

          assert_nil result[:format]
          assert_nil result[:options]
          assert_equal "5m", result[:keep_alive]
        end

        test "cleanup_serialized_request skips default ollama values" do
          openai_hash = { messages: [], model: "llama2" }
          ollama_params = { format: "json", keep_alive: "5m" }
          defaults = { keep_alive: "5m" }
          gem_object = OpenStruct.new(data: {})
          def gem_object.instance_variable_get(key)
            @data ||= {}
            key == :@data ? @data : super
          end

          result = transforms.cleanup_serialized_request(openai_hash, ollama_params, defaults, gem_object)

          assert_nil result[:keep_alive]
        end

        # Integration tests
        test "integration full params normalization with Ollama extensions" do
          params = {
            messages: [
              { role: "user", content: "hello" },
              { role: "user", content: " world" }
            ],
            model: "llama2",
            format: "json",
            options: { temperature: 0.7, num_predict: 100 },
            keep_alive: "10m"
          }

          openai_params, ollama_params = transforms.normalize_params(params)

          # Check OpenAI params
          assert_equal 1, openai_params[:messages].size
          assert_equal "llama2", openai_params[:model]

          # Check Ollama params
          assert_equal "json", ollama_params[:format]
          assert_equal({ temperature: 0.7, num_predict: 100 }, ollama_params[:options])
          assert_equal "10m", ollama_params[:keep_alive]
        end

        test "integration round-trip normalization with grouping" do
          params = {
            messages: [
              { role: "user", content: "hello" },
              { role: "user", content: " world" },
              { role: "assistant", content: "hi" }
            ],
            format: "json"
          }

          openai_params, ollama_params = transforms.normalize_params(params)

          # Simulate what happens in serialization
          serialized = {
            messages: openai_params[:messages].map { |m| { role: m.role, content: m.content } }
          }

          gem_object = OpenStruct.new(data: {})
          def gem_object.instance_variable_get(key)
            @data ||= {}
            key == :@data ? @data : super
          end

          result = transforms.cleanup_serialized_request(serialized, ollama_params, {}, gem_object)

          assert_equal 2, result[:messages].size
          # Content might be merged as array due to OpenAI transforms
          assert result[:messages][0][:content].is_a?(Array) || result[:messages][0][:content].is_a?(String)
          assert_equal "hi", result[:messages][1][:content]
          assert_equal "json", result[:format]
        end
      end
    end
  end
end
