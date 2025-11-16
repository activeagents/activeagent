# frozen_string_literal: true

require "test_helper"
require "ostruct"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping OpenAI Chat transforms tests"
  return
end

require_relative "../../../../lib/active_agent/providers/open_ai/chat/transforms"

module Providers
  module OpenAI
    module Chat
      class TransformsTest < ActiveSupport::TestCase
        private

        def transforms
          ActiveAgent::Providers::OpenAI::Chat::Transforms
        end

        # gem_to_hash tests
        test "gem_to_hash converts object to hash with symbolized keys" do
          mock_object = Minitest::Mock.new
          mock_object.expect(:to_json, '{"role":"user","content":"hello"}')

          result =  transforms.gem_to_hash(mock_object)

          assert_equal({ role: "user", content: "hello" }, result)
          mock_object.verify
        end

        # normalize_params tests
        test "normalize_params_maps_instructions_to_developer_messages" do
          params = {
            instructions: "You are a helpful assistant",
            messages: [ { role: "user", content: "hello" } ]
          }

          result =  transforms.normalize_params(params)

          assert_nil result[:instructions]
          assert_equal 2, result[:messages].size
          assert_equal :developer, result[:messages][0].role
          assert_equal "You are a helpful assistant", result[:messages][0].content
        end

        test "normalize_params normalizes messages when present" do
          params = {
            messages: [ { role: "user", content: "hello" } ]
          }

          result =  transforms.normalize_params(params)

          assert_equal 1, result[:messages].size
          assert_instance_of ::OpenAI::Models::Chat::ChatCompletionUserMessageParam, result[:messages][0]
        end

        test "normalize_params normalizes response_format when present" do
          params = {
            messages: [ { role: "user", content: "hello" } ],
            response_format: :json_object
          }

          result =  transforms.normalize_params(params)

          assert_equal({ type: "json_object" }, result[:response_format])
        end

        test "normalize_params does not modify original params" do
          params = { messages: [ { role: "user", content: "hello" } ] }
          original_keys = params.keys

           transforms.normalize_params(params)

          assert_equal original_keys, params.keys
        end

        # normalize_messages tests
        test "normalize_messages_converts_string_to_user_message" do
          messages = "hello world"

          result =  transforms.normalize_messages(messages)

          assert_equal 1, result.size
          assert_instance_of ::OpenAI::Models::Chat::ChatCompletionUserMessageParam, result[0]
          assert_equal :user, result[0].role
          assert_equal "hello world", result[0].content
        end

        test "normalize_messages converts hash to message param" do
          messages = { role: "assistant", content: "hello" }

          result =  transforms.normalize_messages(messages)

          assert_equal 1, result.size
          assert_instance_of ::OpenAI::Models::Chat::ChatCompletionAssistantMessageParam, result[0]
          assert_equal :assistant, result[0].role
          assert_equal "hello", result[0].content
        end

        test "normalize_messages merges consecutive same-role messages" do
          messages = [
            { role: "user", content: "hello" },
            { role: "user", content: "world" }
          ]

          result =  transforms.normalize_messages(messages)

          assert_equal 1, result.size
          assert_equal :user, result[0].role
          assert_equal 2, result[0].content.size
          assert_equal "hello", result[0].content[0][:text]
          assert_equal "world", result[0].content[1][:text]
        end

        test "normalize_messages keeps separate different-role messages" do
          messages = [
            { role: "user", content: "hello" },
            { role: "assistant", content: "hi there" }
          ]

          result =  transforms.normalize_messages(messages)

          assert_equal 2, result.size
          assert_equal :user, result[0].role
          assert_equal :assistant, result[1].role
        end

        test "normalize_messages returns nil for nil input" do
          result =  transforms.normalize_messages(nil)

          assert_nil result
        end

        test "normalize_messages raises error for invalid input type" do
          assert_raises(ArgumentError) do
             transforms.normalize_messages(123)
          end
        end

        # normalize_message tests
        test "normalize_message converts string to user message" do
          message = "hello"

          result =  transforms.normalize_message(message)

          assert_instance_of ::OpenAI::Models::Chat::ChatCompletionUserMessageParam, result
          assert_equal :user, result.role
          assert_equal "hello", result.content
        end

        test "normalize_message passes through gem message param" do
          message = ::OpenAI::Models::Chat::ChatCompletionUserMessageParam.new(role: "user", content: "hello")

          result =  transforms.normalize_message(message)

          assert_equal message, result
        end

        test "normalize_message handles hash with content" do
          message = { role: "system", content: "You are helpful" }

          result =  transforms.normalize_message(message)

          assert_instance_of ::OpenAI::Models::Chat::ChatCompletionSystemMessageParam, result
          assert_equal :system, result.role
          assert_equal "You are helpful", result.content
        end

        test "normalize_message handles shorthand text format" do
          message = { text: "hello" }

          result =  transforms.normalize_message(message)

          assert_equal :user, result.role
          assert_equal "hello", result.content
        end

        test "normalize_message handles shorthand image format" do
          message = { image: "http://example.com/image.jpg" }

          result =  transforms.normalize_message(message)

          assert_equal :user, result.role
          assert_equal 1, result.content.size
          assert_equal "image_url", result.content[0][:type]
          assert_equal "http://example.com/image.jpg", result.content[0][:image_url][:url]
        end

        test "normalize_message handles text and image shorthand" do
          message = { text: "Check this", image: "http://example.com/image.jpg" }

          result =  transforms.normalize_message(message)

          assert_equal :user, result.role
          assert_equal 2, result.content.size
          assert_equal "text", result.content[0][:type]
          assert_equal "Check this", result.content[0][:text]
          assert_equal "image_url", result.content[1][:type]
        end

        test "normalize_message handles hash without role as user" do
          message = { content: "hello" }

          result =  transforms.normalize_message(message)

          assert_equal :user, result.role
          assert_equal "hello", result.content
        end

        test "normalize_message preserves extra params" do
          message = { role: "assistant", content: "hello", name: "bot" }

          result =  transforms.normalize_message(message)

          assert_equal "bot", result.name
        end

        test "normalize_message raises error for invalid type" do
          assert_raises(ArgumentError) do
             transforms.normalize_message(123)
          end
        end

        # create_message_param tests
        test "create_message_param creates developer message" do
          result =  transforms.create_message_param("developer", "You are helpful")

          assert_instance_of ::OpenAI::Models::Chat::ChatCompletionDeveloperMessageParam, result
          assert_equal :developer, result.role
          assert_equal "You are helpful", result.content
        end

        test "create_message_param creates system message" do
          result =  transforms.create_message_param("system", "You are helpful")

          assert_instance_of ::OpenAI::Models::Chat::ChatCompletionSystemMessageParam, result
          assert_equal :system, result.role
          assert_equal "You are helpful", result.content
        end

        test "create_message_param creates user message" do
          result =  transforms.create_message_param("user", "hello")

          assert_instance_of ::OpenAI::Models::Chat::ChatCompletionUserMessageParam, result
          assert_equal :user, result.role
          assert_equal "hello", result.content
        end

        test "create_message_param creates assistant message" do
          result =  transforms.create_message_param("assistant", "hi there")

          assert_instance_of ::OpenAI::Models::Chat::ChatCompletionAssistantMessageParam, result
          assert_equal :assistant, result.role
          assert_equal "hi there", result.content
        end

        test "create_message_param creates tool message" do
          result =  transforms.create_message_param("tool", "result", { tool_call_id: "123" })

          assert_instance_of ::OpenAI::Models::Chat::ChatCompletionToolMessageParam, result
          assert_equal :tool, result.role
          assert_equal "result", result.content
          assert_equal "123", result.tool_call_id
        end

        test "create_message_param creates function message" do
          result =  transforms.create_message_param("function", "result", { name: "my_func" })

          assert_instance_of ::OpenAI::Models::Chat::ChatCompletionFunctionMessageParam, result
          assert_equal :function, result.role
          assert_equal "result", result.content
        end

        test "create_message_param raises error for unknown role" do
          assert_raises(ArgumentError) do
             transforms.create_message_param("unknown", "content")
          end
        end

        test "create_message_param handles nil content" do
          result =  transforms.create_message_param("user", nil)

          assert_equal :user, result.role
          assert_nil result.content
        end

        test "create_message_param merges extra params" do
          result =  transforms.create_message_param("user", "hello", { name: "alice" })

          assert_equal "alice", result.name
        end

        # normalize_content tests
        test "normalize_content keeps string unchanged" do
          content = "hello world"

          result =  transforms.normalize_content(content)

          assert_equal "hello world", result
        end

        test "normalize_content normalizes array of parts" do
          content = [
            "hello",
            { type: "text", text: "world" }
          ]

          result =  transforms.normalize_content(content)

          assert_equal 2, result.size
          assert_equal({ type: "text", text: "hello" }, result[0])
          assert_equal({ type: "text", text: "world" }, result[1])
        end

        test "normalize_content wraps hash in array" do
          content = { type: "text", text: "hello" }

          result =  transforms.normalize_content(content)

          assert_equal 1, result.size
          assert_equal({ type: "text", text: "hello" }, result[0])
        end

        test "normalize_content returns nil for nil" do
          result =  transforms.normalize_content(nil)

          assert_nil result
        end

        test "normalize_content raises error for invalid type" do
          assert_raises(ArgumentError) do
             transforms.normalize_content(123)
          end
        end

        # normalize_content_part tests
        test "normalize_content_part symbolizes hash keys" do
          part = { "type" => "text", "text" => "hello" }

          result =  transforms.normalize_content_part(part)

          assert_equal({ type: "text", text: "hello" }, result)
        end

        test "normalize_content_part converts string to text part" do
          part = "hello"

          result =  transforms.normalize_content_part(part)

          assert_equal({ type: "text", text: "hello" }, result)
        end

        test "normalize_content_part raises error for invalid type" do
          assert_raises(ArgumentError) do
             transforms.normalize_content_part(123)
          end
        end

        # merge_content tests
        test "merge_content merges two strings" do
          result =  transforms.merge_content("hello", "world")

          assert_equal 2, result.size
          assert_equal "hello", result[0][:text]
          assert_equal "world", result[1][:text]
        end

        test "merge_content merges string and array" do
          result =  transforms.merge_content("hello", [ { type: "text", text: "world" } ])

          assert_equal 2, result.size
          assert_equal "hello", result[0][:text]
          assert_equal "world", result[1][:text]
        end

        test "merge_content merges two arrays" do
          result =  transforms.merge_content(
            [ { type: "text", text: "hello" } ],
            [ { type: "text", text: "world" } ]
          )

          assert_equal 2, result.size
          assert_equal "hello", result[0][:text]
          assert_equal "world", result[1][:text]
        end

        test "merge_content handles nil values" do
          result =  transforms.merge_content(nil, "hello")

          assert_equal 1, result.size
          assert_equal "hello", result[0][:text]
        end

        # content_to_array tests
        test "content_to_array converts string to array" do
          result =  transforms.content_to_array("hello")

          assert_equal 1, result.size
          assert_equal({ type: "text", text: "hello" }, result[0])
        end

        test "content_to_array normalizes array strings" do
          result =  transforms.content_to_array([ "hello", { type: "text", text: "world" } ])

          assert_equal 2, result.size
          assert_equal({ type: "text", text: "hello" }, result[0])
          assert_equal({ type: "text", text: "world" }, result[1])
        end

        test "content_to_array returns empty array for nil" do
          result =  transforms.content_to_array(nil)

          assert_equal [], result
        end

        test "content_to_array wraps unknown types in array" do
          obj = Object.new
          result =  transforms.content_to_array(obj)

          assert_equal [ obj ], result
        end

        # simplify_messages tests
        test "simplify_messages converts single text part to string" do
          messages = [
            { role: "user", content: [ { type: "text", text: "hello" } ] }
          ]

          result =  transforms.simplify_messages(messages)

          assert_equal "hello", result[0][:content]
        end

        test "simplify_messages keeps multi-part content as array" do
          messages = [
            { role: "user", content: [
              { type: "text", text: "hello" },
              { type: "text", text: "world" }
            ] }
          ]

          result =  transforms.simplify_messages(messages)

          assert result[0][:content].is_a?(Array)
          assert_equal 2, result[0][:content].size
        end

        test "simplify_messages removes empty content arrays" do
          messages = [
            { role: "user", content: [] }
          ]

          result =  transforms.simplify_messages(messages)

          assert_nil result[0][:content]
        end

        test "simplify_messages converts gem objects to hashes" do
          gem_msg = ::OpenAI::Models::Chat::ChatCompletionUserMessageParam.new(role: "user", content: "hello")
          messages = [ gem_msg ]

          result =  transforms.simplify_messages(messages)

          assert result[0].is_a?(Hash)
          assert_equal "user", result[0][:role]
          assert_equal "hello", result[0][:content]
        end

        test "simplify_messages returns non-array input unchanged" do
          result =  transforms.simplify_messages(nil)

          assert_nil result
        end

        # normalize_response_format tests
        test "normalize_response_format converts symbol to hash" do
          result =  transforms.normalize_response_format(:json_object)

          assert_equal({ type: "json_object" }, result)
        end

        test "normalize_response_format converts string to hash" do
          result =  transforms.normalize_response_format("text")

          assert_equal({ type: "text" }, result)
        end

        test "normalize_response_format handles json_schema format" do
          format = {
            type: "json_schema",
            name: "my_schema",
            schema: { type: "object" }
          }

          result =  transforms.normalize_response_format(format)

          assert_equal "json_schema", result[:type]
          assert_equal "my_schema", result[:json_schema][:name]
          assert_equal({ type: "object" }, result[:json_schema][:schema])
        end

        test "normalize_response_format handles nested json_schema" do
          format = {
            type: :json_schema,
            json_schema: {
              name: "my_schema",
              schema: { type: "object" },
              strict: true
            }
          }

          result =  transforms.normalize_response_format(format)

          assert_equal "json_schema", result[:type]
          assert_equal "my_schema", result[:json_schema][:name]
          assert_equal true, result[:json_schema][:strict]
        end

        test "normalize_response_format passes through complex structures" do
          format = { custom: "format" }

          result =  transforms.normalize_response_format(format)

          assert_equal({ custom: "format" }, result)
        end

        # normalize_instructions tests
        test "normalize_instructions converts string to developer message" do
          result =  transforms.normalize_instructions("You are helpful")

          assert_equal 1, result.size
          assert_equal "developer", result[0][:role]
          assert_equal "You are helpful", result[0][:content]
        end

        test "normalize_instructions converts multiple instructions to content parts" do
          result =  transforms.normalize_instructions([ "First instruction", "Second instruction" ])

          assert_equal 1, result.size
          assert_equal "developer", result[0][:role]
          assert_equal 2, result[0][:content].size
          assert_equal "text", result[0][:content][0][:type]
          assert_equal "First instruction", result[0][:content][0][:text]
        end

        # cleanup_serialized_request tests
        test "cleanup_serialized_request removes default values" do
          hash = { model: "gpt-4", temperature: 1.0, messages: [] }
          defaults = { temperature: 1.0, top_p: 1.0 }
          gem_object = OpenStruct.new(data: {})
          def gem_object.instance_variable_get(key)
            @data ||= {}
            key == :@data ? @data : super
          end

          result =  transforms.cleanup_serialized_request(hash, defaults, gem_object)

          assert_nil result[:temperature]
          assert_equal "gpt-4", result[:model]
        end

        test "cleanup_serialized_request simplifies messages" do
          hash = {
            messages: [
              { role: "user", content: [ { type: "text", text: "hello" } ] }
            ]
          }
          gem_object = OpenStruct.new(data: {})
          def gem_object.instance_variable_get(key)
            @data ||= {}
            key == :@data ? @data : super
          end

          result =  transforms.cleanup_serialized_request(hash, {}, gem_object)

          assert_equal "hello", result[:messages][0][:content]
        end

        test "cleanup_serialized_request adds web_search_options if present in gem object" do
          hash = { model: "gpt-4", messages: [] }
          gem_object = OpenStruct.new(data: { web_search_options: {} })
          def gem_object.instance_variable_get(key)
            key == :@data ? { web_search_options: {} } : super
          end

          result =  transforms.cleanup_serialized_request(hash, {}, gem_object)

          assert_equal({}, result[:web_search_options])
        end

        # Integration tests
        test "full message normalization with mixed formats" do
          messages = [
            "Hello",
            { text: "How are you?" },
            { role: "assistant", content: "I'm fine" },
            { text: "Good", image: "http://example.com/image.jpg" }
          ]

          result =  transforms.normalize_messages(messages)

          assert_equal 3, result.size
          assert_equal :user, result[0].role
          assert_equal :assistant, result[1].role
          assert_equal :user, result[2].role
        end

        test "round-trip normalization and simplification" do
          messages = [ { role: "user", content: "hello" } ]

          normalized =  transforms.normalize_messages(messages)
          hashes = normalized.map { |msg|  transforms.gem_to_hash(msg) }
          simplified =  transforms.simplify_messages(hashes)

          assert_equal "hello", simplified[0][:content]
        end

        test "instructions integration with messages" do
          params = {
            instructions: [ "First", "Second" ],
            messages: [ "Hello" ]
          }

          result =  transforms.normalize_params(params)

          assert_equal 2, result[:messages].size
          assert_equal :developer, result[:messages][0].role
          assert_equal 2, result[:messages][0].content.size
          assert_equal :user, result[:messages][1].role
        end
      end
    end
  end
end
