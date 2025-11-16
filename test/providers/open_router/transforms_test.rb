# frozen_string_literal: true

require "test_helper"
require "ostruct"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping OpenRouter transforms tests"
  return
end

require_relative "../../../lib/active_agent/providers/open_router/transforms"

module Providers
  module OpenRouter
    class TransformsTest < ActiveSupport::TestCase
      private

      def transforms
        ActiveAgent::Providers::OpenRouter::Transforms
      end

      # gem_to_hash tests
      test "gem_to_hash delegates to OpenAI transforms" do
        obj = Object.new
        def obj.to_json
          '{"role":"user","content":"hello"}'
        end

        result =  transforms.gem_to_hash(obj)

        assert_equal({ role: "user", content: "hello" }, result)
      end

      # normalize_params tests
      test "normalize_params extracts OpenRouter-specific parameters" do
        params = {
          messages: [ { role: "user", content: "hello" } ],
          plugins: [ "web_search" ],
          provider: { order: [ "anthropic", "openai" ] },
          transforms: [ "middle-out" ],
          models: [ "anthropic/claude-3-5-sonnet" ],
          route: "fallback"
        }

        openai_params, openrouter_params =  transforms.normalize_params(params)

        assert_equal [ "web_search" ], openrouter_params[:plugins]
        assert_equal({ order: [ "anthropic", "openai" ] }, openrouter_params[:provider])
        assert_equal [ "middle-out" ], openrouter_params[:transforms]
        assert_equal [ "anthropic/claude-3-5-sonnet" ], openrouter_params[:models]
        assert_equal "fallback", openrouter_params[:route]
      end

      test "normalize_params extracts OpenRouter-specific sampling parameters" do
        params = {
          messages: [ { role: "user", content: "hello" } ],
          top_k: 50,
          min_p: 0.05,
          top_a: 0.1,
          repetition_penalty: 1.1
        }

        openai_params, openrouter_params =  transforms.normalize_params(params)

        assert_equal 50, openrouter_params[:top_k]
        assert_equal 0.05, openrouter_params[:min_p]
        assert_equal 0.1, openrouter_params[:top_a]
        assert_equal 1.1, openrouter_params[:repetition_penalty]
        refute openai_params.key?(:top_k)
      end

      test "normalize_params sets require_parameters for json_object response_format" do
        params = {
          messages: [ { role: "user", content: "hello" } ],
          response_format: { type: :json_object }
        }

        _openai_params, openrouter_params =  transforms.normalize_params(params)

        assert_equal true, openrouter_params[:provider][:require_parameters]
      end

      test "normalize_params sets require_parameters for json_schema response_format" do
        params = {
          messages: [ { role: "user", content: "hello" } ],
          response_format: {
            type: :json_schema,
            json_schema: { name: "test", schema: { type: "object" } }
          }
        }

        _openai_params, openrouter_params =  transforms.normalize_params(params)

        assert_equal true, openrouter_params[:provider][:require_parameters]
      end

      test "normalize_params merges with existing provider settings" do
        params = {
          messages: [ { role: "user", content: "hello" } ],
          provider: { order: [ "anthropic" ] },
          response_format: { type: :json_object }
        }

        _openai_params, openrouter_params =  transforms.normalize_params(params)

        assert_equal [ "anthropic" ], openrouter_params[:provider][:order]
        assert_equal true, openrouter_params[:provider][:require_parameters]
      end

      test "normalize_params delegates to OpenAI transforms for base params" do
        params = {
          instructions: "You are helpful",
          messages: [ { role: "user", content: "hello" } ]
        }

        openai_params, openrouter_params =  transforms.normalize_params(params)

        assert_equal 2, openai_params[:messages].size
        assert_equal :developer, openai_params[:messages][0].role
        assert_empty openrouter_params
      end

      # normalize_messages tests
      test "normalize_messages delegates to OpenAI transforms" do
        messages = [
          { role: "user", content: "hello" },
          { role: "assistant", content: "hi" }
        ]

        result =  transforms.normalize_messages(messages)

        assert_equal 2, result.size
        assert_instance_of ::OpenAI::Models::Chat::ChatCompletionUserMessageParam, result[0]
        assert_instance_of ::OpenAI::Models::Chat::ChatCompletionAssistantMessageParam, result[1]
      end

      # normalize_response_format tests
      test "normalize_response_format delegates to OpenAI transforms" do
        format = { type: "json_schema", name: "test", schema: { type: "object" } }

        result =  transforms.normalize_response_format(format)

        assert_equal({ type: "json_schema", json_schema: { name: "test", schema: { type: "object" } } }, result)
      end

      # serialize_openrouter_param tests
      test "serialize_openrouter_param serializes provider with serialize method" do
        provider = Object.new
        def provider.respond_to?(method)
          method == :serialize || super
        end
        def provider.serialize
          { order: [ "anthropic" ], require_parameters: true }
        end

        result =  transforms.serialize_openrouter_param(:provider, provider)

        assert_equal({ order: [ "anthropic" ], require_parameters: true }, result)
      end

      test "serialize_openrouter_param passes through provider without serialize method" do
        provider = { order: [ "openai" ] }

        result =  transforms.serialize_openrouter_param(:provider, provider)

        assert_equal({ order: [ "openai" ] }, result)
      end

      test "serialize_openrouter_param serializes plugins array" do
        plugin1 = Object.new
        def plugin1.respond_to?(method)
          method == :serialize || super
        end
        def plugin1.serialize
          { name: "web_search", enabled: true }
        end

        plugin2 = { name: "custom", enabled: false }

        result =  transforms.serialize_openrouter_param(:plugins, [ plugin1, plugin2 ])

        assert_equal 2, result.size
        assert_equal({ name: "web_search", enabled: true }, result[0])
        assert_equal({ name: "custom", enabled: false }, result[1])
      end

      test "serialize_openrouter_param passes through other params" do
        result =  transforms.serialize_openrouter_param(:route, "fallback")

        assert_equal "fallback", result
      end

      # cleanup_serialized_request tests
      test "cleanup_serialized_request merges openrouter params" do
        openai_hash = { messages: [ { role: "user", content: "hello" } ], model: "anthropic/claude-3-5-sonnet" }
        openrouter_params = { plugins: [ "web_search" ], transforms: [ "middle-out" ] }
        defaults = {}
        gem_object = OpenStruct.new(data: {})
        def gem_object.instance_variable_get(key)
          @data ||= {}
          key == :@data ? @data : super
        end

        result =  transforms.cleanup_serialized_request(openai_hash, openrouter_params, defaults, gem_object)

        assert_equal [ "web_search" ], result[:plugins]
        assert_equal [ "middle-out" ], result[:transforms]
        assert_equal "anthropic/claude-3-5-sonnet", result[:model]
      end

      test "cleanup_serialized_request skips nil and empty openrouter params" do
        openai_hash = { messages: [], model: "test" }
        openrouter_params = { plugins: nil, transforms: [], route: "fallback" }
        defaults = {}
        gem_object = OpenStruct.new(data: {})
        def gem_object.instance_variable_get(key)
          @data ||= {}
          key == :@data ? @data : super
        end

        result =  transforms.cleanup_serialized_request(openai_hash, openrouter_params, defaults, gem_object)

        assert_nil result[:plugins]
        assert_nil result[:transforms]
        assert_equal "fallback", result[:route]
      end

      test "cleanup_serialized_request skips default openrouter values" do
        openai_hash = { messages: [], model: "test" }
        openrouter_params = { route: "fallback", plugins: [ "web_search" ] }
        defaults = { route: "fallback" }
        gem_object = OpenStruct.new(data: {})
        def gem_object.instance_variable_get(key)
          @data ||= {}
          key == :@data ? @data : super
        end

        result =  transforms.cleanup_serialized_request(openai_hash, openrouter_params, defaults, gem_object)

        assert_nil result[:route]
        assert_equal [ "web_search" ], result[:plugins]
      end

      test "cleanup_serialized_request serializes provider param" do
        provider = Object.new
        def provider.respond_to?(method)
          method == :serialize || super
        end
        def provider.serialize
          { order: [ "anthropic" ] }
        end

        openai_hash = { messages: [], model: "test" }
        openrouter_params = { provider: provider }
        defaults = {}
        gem_object = OpenStruct.new(data: {})
        def gem_object.instance_variable_get(key)
          @data ||= {}
          key == :@data ? @data : super
        end

        result =  transforms.cleanup_serialized_request(openai_hash, openrouter_params, defaults, gem_object)

        assert_equal({ order: [ "anthropic" ] }, result[:provider])
      end

      # Integration tests
      test "full params normalization with OpenRouter extensions" do
        params = {
          messages: [ { role: "user", content: "hello" } ],
          model: "anthropic/claude-3-5-sonnet",
          plugins: [ "web_search" ],
          transforms: [ "middle-out" ],
          top_k: 50,
          response_format: { type: :json_object }
        }

        openai_params, openrouter_params =  transforms.normalize_params(params)

        assert_equal 1, openai_params[:messages].size
        assert_equal "anthropic/claude-3-5-sonnet", openai_params[:model]
        assert_equal [ "web_search" ], openrouter_params[:plugins]
        assert_equal [ "middle-out" ], openrouter_params[:transforms]
        assert_equal 50, openrouter_params[:top_k]
        assert_equal true, openrouter_params[:provider][:require_parameters]
      end

      test "round-trip normalization with structured output" do
        params = {
          messages: [ { role: "user", content: "extract data" } ],
          response_format: {
            type: :json_schema,
            json_schema: {
              name: "extraction",
              schema: { type: "object", properties: { name: { type: "string" } } }
            }
          }
        }

        openai_params, openrouter_params =  transforms.normalize_params(params)

        serialized = {
          messages: openai_params[:messages].map { |m| { role: m.role, content: m.content } },
          response_format: openai_params[:response_format]
        }

        gem_object = OpenStruct.new(data: {})
        def gem_object.instance_variable_get(key)
          @data ||= {}
          key == :@data ? @data : super
        end

        result =  transforms.cleanup_serialized_request(serialized, openrouter_params, {}, gem_object)

        assert_equal true, result[:provider][:require_parameters]
        assert_equal "json_schema", result[:response_format][:type]
      end
    end
  end
end
