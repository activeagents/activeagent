# frozen_string_literal: true

require "test_helper"
require "ostruct"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping OpenAI Responses transforms tests"
  return
end

require_relative "../../../../lib/active_agent/providers/open_ai/responses/transforms"

module Providers
  module OpenAI
    module Responses
      class TransformsTest < ActiveSupport::TestCase
        private

        def transforms
          ActiveAgent::Providers::OpenAI::Responses::Transforms
        end

        # gem_to_hash tests
        test "gem_to_hash converts object to hash with symbolized keys" do
          mock_object = Minitest::Mock.new
          mock_object.expect(:to_json, '{"input":"hello","modalities":["text"]}')

          result =  transforms.gem_to_hash(mock_object)

          assert_equal({ input: "hello", modalities: [ "text" ] }, result)
          mock_object.verify
        end

        # simplify_input tests
        test "simplify_input unwraps single string array" do
          input = [ "hello world" ]

          result =  transforms.simplify_input(input)

          assert_equal "hello world", result
        end

        test "simplify_input unwraps single input_text object" do
          input = [ { type: "input_text", text: "hello" } ]

          result =  transforms.simplify_input(input)

          assert_equal "hello", result
        end

        test "simplify_input unwraps single user message with string content" do
          input = [ { role: "user", content: "hello" } ]

          result =  transforms.simplify_input(input)

          assert_equal "hello", result
        end

        test "simplify_input keeps multi-element arrays" do
          input = [ "hello", "world" ]

          result =  transforms.simplify_input(input)

          assert_equal [ "hello", "world" ], result
        end

        test "simplify_input keeps input_text with extra keys" do
          input = [ { type: "input_text", text: "hello", extra: "data" } ]

          result =  transforms.simplify_input(input)

          assert_equal input, result
        end

        test "simplify_input returns non-array unchanged" do
          input = "hello"

          result =  transforms.simplify_input(input)

          assert_equal "hello", result
        end

        # normalize_response_format tests
        test "normalize_response_format converts symbol to ResponseTextConfig" do
          result =  transforms.normalize_response_format(:json_object)

          assert_instance_of ::OpenAI::Models::Responses::ResponseTextConfig, result
          # Verify by serializing to hash
          hash =  transforms.gem_to_hash(result)
          assert_equal "json_object", hash[:format][:type]
        end

        test "normalize_response_format converts string to ResponseTextConfig" do
          result =  transforms.normalize_response_format("text")

          assert_instance_of ::OpenAI::Models::Responses::ResponseTextConfig, result
          # Verify by serializing to hash
          hash =  transforms.gem_to_hash(result)
          assert_equal "text", hash[:format][:type]
        end

        test "normalize_response_format handles json_schema format" do
          format = {
            type: "json_schema",
            name: "my_schema",
            schema: { type: "object", properties: { name: { type: "string" } } }
          }

          result =  transforms.normalize_response_format(format)

          assert_instance_of ::OpenAI::Models::Responses::ResponseTextConfig, result
          # Verify by serializing to hash
          hash =  transforms.gem_to_hash(result)
          assert_equal "json_schema", hash[:format][:type]
          assert_equal "my_schema", hash[:format][:name]
          assert_equal({ type: "object", properties: { name: { type: "string" } } }, hash[:format][:schema])
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

          assert_instance_of ::OpenAI::Models::Responses::ResponseTextConfig, result
          # Verify by serializing to hash
          hash =  transforms.gem_to_hash(result)
          assert_equal "json_schema", hash[:format][:type]
          assert_equal "my_schema", hash[:format][:name]
          assert hash[:format][:strict]
        end

        test "normalize_response_format handles json_object format" do
          format = { type: :json_object }

          result =  transforms.normalize_response_format(format)

          assert_instance_of ::OpenAI::Models::Responses::ResponseTextConfig, result
          # Verify by serializing to hash
          hash =  transforms.gem_to_hash(result)
          assert_equal "json_object", hash[:format][:type]
        end

        test "normalize_response_format wraps simple type in format key" do
          format = { type: "text" }

          result =  transforms.normalize_response_format(format)

          assert_instance_of ::OpenAI::Models::Responses::ResponseTextConfig, result
          # Verify by serializing to hash
          hash =  transforms.gem_to_hash(result)
          assert_equal "text", hash[:format][:type]
        end

        # normalize_input tests
        test "normalize_input keeps string unchanged" do
          input = "hello world"

          result =  transforms.normalize_input(input)

          assert_equal "hello world", result
        end

        test "normalize_input wraps hash in array" do
          input = { text: "hello" }

          result =  transforms.normalize_input(input)

          assert_equal 1, result.size
          assert_equal "user", result[0][:role]
          assert_equal "hello", result[0][:content]
        end

        test "normalize_input wraps content items in user message" do
          input = [
            { text: "Check this" },
            { image: "http://example.com/image.jpg" }
          ]

          result =  transforms.normalize_input(input)

          assert_equal 1, result.size
          assert_equal "user", result[0][:role]
          assert_equal 2, result[0][:content].size
          # The first item is normalized to a user message with single text key, not input_text
          assert result[0][:content][0].is_a?(Hash)
          assert_equal "input_image", result[0][:content][1][:type]
        end

        test "normalize_input treats array of messages as messages" do
          input = [
            { role: "user", content: "hello" },
            { role: "assistant", content: "hi" }
          ]

          result =  transforms.normalize_input(input)

          assert_equal 2, result.size
          assert_equal "user", result[0][:role]
          assert_equal "assistant", result[1][:role]
        end

        test "normalize_input treats array of strings as content items" do
          input = [ "hello", "world" ]

          result =  transforms.normalize_input(input)

          assert_equal 1, result.size
          assert_equal "user", result[0][:role]
          assert_equal 2, result[0][:content].size
          assert_equal "input_text", result[0][:content][0][:type]
          assert_equal "hello", result[0][:content][0][:text]
        end

        # normalize_message tests
        test "normalize_message converts string to input_text in content context" do
          result =  transforms.normalize_message("hello", context: :content)

          assert_equal({ type: "input_text", text: "hello" }, result)
        end

        test "normalize_message converts string to user message in input context" do
          result =  transforms.normalize_message("hello", context: :input)

          assert_equal({ role: "user", content: "hello" }, result)
        end

        test "normalize_message handles hash with role" do
          message = { role: "user", content: "hello" }

          result =  transforms.normalize_message(message)

          assert_equal({ role: "user", content: "hello" }, result)
        end

        test "normalize_message converts text to content for message hash" do
          message = { role: "assistant", text: "hello" }

          result =  transforms.normalize_message(message)

          assert_equal "assistant", result[:role]
          assert_equal "hello", result[:content]
          assert_nil result[:text]
        end

        test "normalize_message handles image shorthand" do
          message = { image: "http://example.com/image.jpg" }

          result =  transforms.normalize_message(message)

          assert_equal "input_image", result[:type]
          assert_equal "http://example.com/image.jpg", result[:image_url]
        end

        test "normalize_message handles document URL shorthand" do
          message = { document: "http://example.com/doc.pdf" }

          result =  transforms.normalize_message(message)

          assert_equal "input_file", result[:type]
          assert_equal "http://example.com/doc.pdf", result[:file_url]
        end

        test "normalize_message handles document data URI shorthand" do
          message = { document: "data:application/pdf;base64,JVBERi0xLjQ" }

          result =  transforms.normalize_message(message)

          assert_equal "input_file", result[:type]
          assert_equal "document.pdf", result[:filename]
          assert_equal "data:application/pdf;base64,JVBERi0xLjQ", result[:file_data]
        end

        test "normalize_message converts single text key to user message" do
          message = { text: "hello" }

          result =  transforms.normalize_message(message)

          assert_equal "user", result[:role]
          assert_equal "hello", result[:content]
        end

        test "normalize_message converts text with other keys to input_text" do
          message = { text: "hello", extra: "data" }

          result =  transforms.normalize_message(message)

          assert_equal "input_text", result[:type]
          assert_equal "hello", result[:text]
        end

        test "normalize_message calls serialize on serializable objects" do
          serializable = OpenStruct.new
          def serializable.serialize
            { role: "user", content: "hello" }
          end

          result =  transforms.normalize_message(serializable)

          assert_equal({ role: "user", content: "hello" }, result)
        end

        # cleanup_serialized_request tests
        test "cleanup_serialized_request removes default values" do
          hash = { input: "hello", temperature: 1.0, modalities: [ "text" ] }
          defaults = { temperature: 1.0 }

          result =  transforms.cleanup_serialized_request(hash, defaults, nil)

          assert_nil result[:temperature]
          assert_equal "hello", result[:input]
          assert_equal [ "text" ], result[:modalities]
        end

        test "cleanup_serialized_request simplifies input" do
          hash = { input: [ { type: "input_text", text: "hello" } ] }

          result =  transforms.cleanup_serialized_request(hash, {}, nil)

          assert_equal "hello", result[:input]
        end

        test "cleanup_serialized_request keeps complex input" do
          hash = { input: [
            { type: "input_text", text: "hello" },
            { type: "input_image", image_url: "http://example.com" }
          ] }

          result =  transforms.cleanup_serialized_request(hash, {}, nil)

          assert result[:input].is_a?(Array)
          assert_equal 2, result[:input].size
        end

        # Integration tests
        test "full input normalization with mixed content" do
          input = [
            "Check this image:",
            { image: "http://example.com/image.jpg" },
            { document: "http://example.com/doc.pdf" }
          ]

          result =  transforms.normalize_input(input)

          assert_equal 1, result.size
          assert_equal "user", result[0][:role]
          assert_equal 3, result[0][:content].size
          assert_equal "input_text", result[0][:content][0][:type]
          assert_equal "input_image", result[0][:content][1][:type]
          assert_equal "input_file", result[0][:content][2][:type]
        end

        test "round-trip normalization and simplification" do
          input = { text: "hello" }

          normalized =  transforms.normalize_input(input)
          simplified =  transforms.simplify_input(normalized)

          assert_equal "hello", simplified
        end

        test "response_format normalization preserves structure" do
          format = {
            type: "json_schema",
            name: "response",
            schema: { type: "object", properties: { answer: { type: "string" } } },
            strict: true
          }

          result =  transforms.normalize_response_format(format)

          assert_instance_of ::OpenAI::Models::Responses::ResponseTextConfig, result
          # Verify by serializing to hash
          hash =  transforms.gem_to_hash(result)
          assert_equal "json_schema", hash[:format][:type]
          assert_equal "response", hash[:format][:name]
          assert hash[:format][:strict]
        end

        # normalize_mcp_servers tests
        test "normalize_mcp_servers converts common format to OpenAI format" do
          servers = [
            { name: "stripe", url: "https://mcp.stripe.com", authorization: "sk_test_123" }
          ]

          result = transforms.normalize_mcp_servers(servers)

          assert_equal 1, result.size
          assert_equal "mcp", result[0][:type]
          assert_equal "stripe", result[0][:server_label]
          assert_equal "https://mcp.stripe.com", result[0][:server_url]
          assert_equal "sk_test_123", result[0][:authorization]
        end

        test "normalize_mcp_servers handles multiple servers" do
          servers = [
            { name: "stripe", url: "https://mcp.stripe.com", authorization: "token1" },
            { name: "github", url: "https://api.githubcopilot.com/mcp/", authorization: "token2" }
          ]

          result = transforms.normalize_mcp_servers(servers)

          assert_equal 2, result.size
          assert_equal "stripe", result[0][:server_label]
          assert_equal "github", result[1][:server_label]
        end

        test "normalize_mcp_servers handles server without authorization" do
          servers = [
            { name: "public", url: "https://demo.mcp.example.com" }
          ]

          result = transforms.normalize_mcp_servers(servers)

          assert_equal 1, result.size
          assert_equal "mcp", result[0][:type]
          assert_equal "public", result[0][:server_label]
          assert_equal "https://demo.mcp.example.com", result[0][:server_url]
          assert_nil result[0][:authorization]
        end

        test "normalize_mcp_servers returns already normalized servers as-is" do
          servers = [
            { type: "mcp", server_label: "stripe", server_url: "https://mcp.stripe.com", authorization: "token" }
          ]

          result = transforms.normalize_mcp_servers(servers)

          assert_equal servers, result
        end

        test "normalize_mcp_servers handles alternative field names" do
          servers = [
            { server_label: "stripe", server_url: "https://mcp.stripe.com", authorization: "token" }
          ]

          result = transforms.normalize_mcp_servers(servers)

          assert_equal 1, result.size
          assert_equal "mcp", result[0][:type]
          assert_equal "stripe", result[0][:server_label]
        end

        test "normalize_mcp_servers returns nil for nil input" do
          result = transforms.normalize_mcp_servers(nil)

          assert_nil result
        end

        test "normalize_mcp_servers returns empty array for empty array" do
          result = transforms.normalize_mcp_servers([])

          assert_equal [], result
        end
      end
    end
  end
end
