# frozen_string_literal: true

require "test_helper"
require_relative "../../../lib/active_agent/providers/anthropic/transforms"

module Providers
  module Anthropic
    class TransformsTest < ActiveSupport::TestCase
      private

      def transforms
        ActiveAgent::Providers::Anthropic::Transforms
      end

      # gem_to_hash tests
      test "gem_to_hash converts object to hash" do
        mock_object = Minitest::Mock.new
        mock_object.expect(:to_json, '{"role":"user","content":"hello"}')

        result = transforms.gem_to_hash(mock_object)

        assert_equal({ role: "user", content: "hello" }, result)
        mock_object.verify
      end

      # normalize_params tests
      test "normalize_params normalizes messages" do
        params = { messages: [ { role: "user", content: "hello" } ] }

        result = transforms.normalize_params(params)

        assert_equal 1, result[:messages].size
        assert_equal :user, result[:messages][0][:role]
        assert_equal [ { type: "text", text: "hello" } ], result[:messages][0][:content]
      end

      test "normalize_params normalizes system" do
        params = { system: "You are helpful" }

        result = transforms.normalize_params(params)

        assert_equal "You are helpful", result[:system]
      end

      test "normalize_params does not modify original" do
        params = { messages: [ { role: "user", content: "hello" } ] }
        original = params.dup

        transforms.normalize_params(params)

        assert_equal original, params
      end

      # normalize_messages tests
      test "normalize_messages converts string to user message" do
        result = transforms.normalize_messages([ "hello" ])

        assert_equal 1, result.size
        assert_equal :user, result[0][:role]
        assert_equal [ { type: "text", text: "hello" } ], result[0][:content]
      end

      test "normalize_messages merges consecutive same-role messages" do
        messages = [
          { role: "user", content: "hello" },
          { role: "user", content: "world" }
        ]

        result = transforms.normalize_messages(messages)

        assert_equal 1, result.size
        assert_equal :user, result[0][:role]
        assert_equal 2, result[0][:content].size
        assert_equal "hello", result[0][:content][0][:text]
        assert_equal "world", result[0][:content][1][:text]
      end

      test "normalize_messages keeps different-role messages separate" do
        messages = [
          { role: "user", content: "hello" },
          { role: "assistant", content: "hi there" }
        ]

        result = transforms.normalize_messages(messages)

        assert_equal 2, result.size
        assert_equal :user, result[0][:role]
        assert_equal :assistant, result[1][:role]
      end

      test "normalize_messages defaults to user role" do
        result = transforms.normalize_messages([ { content: "hello" } ])

        assert_equal :user, result[0][:role]
      end

      test "normalize_messages handles text key" do
        result = transforms.normalize_messages([ { role: "assistant", text: "hello" } ])

        assert_equal :assistant, result[0][:role]
        assert_equal [ { type: "text", text: "hello" } ], result[0][:content]
      end

      test "normalize_messages returns nil for nil" do
        assert_nil transforms.normalize_messages(nil)
      end

      # normalize_system tests
      test "normalize_system keeps string unchanged" do
        result = transforms.normalize_system("You are helpful")

        assert_equal "You are helpful", result
      end

      test "normalize_system converts hash to array" do
        result = transforms.normalize_system({ text: "You are helpful" })

        assert_equal 1, result.size
        assert_equal "text", result[0][:type]
        assert_equal "You are helpful", result[0][:text]
      end

      test "normalize_system normalizes array of blocks" do
        result = transforms.normalize_system([ "You are helpful", { text: "Be concise" } ])

        assert_equal 2, result.size
        assert_equal "text", result[0][:type]
        assert_equal "You are helpful", result[0][:text]
        assert_equal "text", result[1][:type]
        assert_equal "Be concise", result[1][:text]
      end

      # normalize_system_block tests
      test "normalize_system_block converts string to text block" do
        result = transforms.normalize_system_block("You are helpful")

        assert_equal({ type: "text", text: "You are helpful" }, result)
      end

      test "normalize_system_block adds type to hash" do
        result = transforms.normalize_system_block({ text: "You are helpful" })

        assert_equal "text", result[:type]
        assert_equal "You are helpful", result[:text]
      end

      test "normalize_system_block keeps complete hash unchanged" do
        block = { type: "text", text: "hello", cache_control: { type: "ephemeral" } }

        assert_equal block, transforms.normalize_system_block(block)
      end

      # normalize_content tests
      test "normalize_content converts string to text block array" do
        content = "hello world"

        result =  transforms.normalize_content(content)

        assert_equal 1, result.size
        assert_equal "text", result[0][:type]
        assert_equal "hello world", result[0][:text]
      end

      test "normalize_content handles array of items" do
        content = [ "hello", { text: "world" } ]

        result =  transforms.normalize_content(content)

        assert_equal 2, result.size
        assert_equal "text", result[0][:type]
        assert_equal "hello", result[0][:text]
        assert_equal "text", result[1][:type]
        assert_equal "world", result[1][:text]
      end

      test "normalize_content expands hash with multiple content keys" do
        content = { text: "hello", image: "http://example.com/image.jpg" }

        result =  transforms.normalize_content(content)

        assert_equal 2, result.size
        assert_equal "text", result[0][:type]
        assert_equal "hello", result[0][:text]
        assert_equal "image", result[1][:type]
      end

      test "normalize_content handles hash with single content key" do
        content = { text: "hello" }

        result =  transforms.normalize_content(content)

        assert_equal 1, result.size
        assert_equal "text", result[0][:type]
        assert_equal "hello", result[0][:text]
      end

      test "normalize_content returns empty array for nil" do
        content = nil

        result =  transforms.normalize_content(content)

        assert_equal [], result
      end

      # normalize_content_item tests
      test "normalize_content_item converts string to text block" do
        item = "hello"

        result =  transforms.normalize_content_item(item)

        assert_equal({ type: "text", text: "hello" }, result)
      end

      test "normalize_content_item adds type to text hash" do
        item = { text: "hello" }

        result =  transforms.normalize_content_item(item)

        assert_equal "text", result[:type]
        assert_equal "hello", result[:text]
      end

      test "normalize_content_item normalizes image hash" do
        item = { image: "http://example.com/image.jpg" }

        result =  transforms.normalize_content_item(item)

        assert_equal "image", result[:type]
        assert_equal "url", result[:source][:type]
        assert_equal "http://example.com/image.jpg", result[:source][:url]
      end

      test "normalize_content_item normalizes document hash" do
        item = { document: "http://example.com/doc.pdf" }

        result =  transforms.normalize_content_item(item)

        assert_equal "document", result[:type]
        assert_equal "url", result[:source][:type]
        assert_equal "http://example.com/doc.pdf", result[:source][:url]
      end

      test "normalize_content_item identifies tool_result" do
        item = { tool_use_id: "123", content: "result" }

        result =  transforms.normalize_content_item(item)

        assert_equal "tool_result", result[:type]
        assert_equal "123", result[:tool_use_id]
      end

      test "normalize_content_item identifies tool_use" do
        item = { id: "123", name: "get_weather", input: { location: "NYC" } }

        result =  transforms.normalize_content_item(item)

        assert_equal "tool_use", result[:type]
        assert_equal "123", result[:id]
        assert_equal "get_weather", result[:name]
      end

      test "normalize_content_item returns hash with type unchanged" do
        item = { type: "text", text: "hello" }

        result =  transforms.normalize_content_item(item)

        assert_equal item, result
      end

      # normalize_source tests
      test "normalize_source wraps URL string in url source type" do
        source = "http://example.com/image.jpg"

        result =  transforms.normalize_source(source)

        assert_equal "url", result[:type]
        assert_equal "http://example.com/image.jpg", result[:url]
      end

      test "normalize_source parses data URI" do
        source = "data:image/png;base64,iVBORw0KGgoAAAANS"

        result =  transforms.normalize_source(source)

        assert_equal "base64", result[:type]
        assert_equal "image/png", result[:media_type]
        assert_equal "iVBORw0KGgoAAAANS", result[:data]
      end

      test "normalize_source handles data URI without base64 marker" do
        source = "data:text/plain,hello%20world"

        result =  transforms.normalize_source(source)

        assert_equal "base64", result[:type]
        assert_equal "text/plain", result[:media_type]
        assert_equal "hello%20world", result[:data]
      end

      test "normalize_source adds type to hash with data and media_type" do
        source = { data: "iVBORw0KGgoAAAANS", media_type: "image/png" }

        result =  transforms.normalize_source(source)

        assert_equal "base64", result[:type]
        assert_equal "iVBORw0KGgoAAAANS", result[:data]
        assert_equal "image/png", result[:media_type]
      end

      test "normalize_source returns hash with type unchanged" do
        source = { type: "url", url: "http://example.com/image.jpg" }

        result =  transforms.normalize_source(source)

        assert_equal source, result
      end

      # parse_data_uri tests
      test "parse_data_uri extracts media type and data from data URI" do
        data_uri = "data:image/png;base64,iVBORw0KGgoAAAANS"

        result =  transforms.parse_data_uri(data_uri)

        assert_equal "base64", result[:type]
        assert_equal "image/png", result[:media_type]
        assert_equal "iVBORw0KGgoAAAANS", result[:data]
      end

      test "parse_data_uri handles data URI without base64 marker" do
        data_uri = "data:text/plain,hello"

        result =  transforms.parse_data_uri(data_uri)

        assert_equal "base64", result[:type]
        assert_equal "text/plain", result[:media_type]
        assert_equal "hello", result[:data]
      end

      test "parse_data_uri returns url fallback for invalid data URI" do
        data_uri = "not-a-data-uri"

        result =  transforms.parse_data_uri(data_uri)

        assert_equal "url", result[:type]
        assert_equal "not-a-data-uri", result[:url]
      end

      # compress_content tests
      test "compress_content compresses message content" do
        hash = {
          messages: [
            { role: "user", content: [ { type: "text", text: "hello" } ] }
          ]
        }

        result =  transforms.compress_content(hash)

        assert_equal "hello", result[:messages][0][:content]
      end

      test "compress_content compresses system content" do
        hash = {
          system: [ { type: "text", text: "You are helpful" } ]
        }

        result =  transforms.compress_content(hash)

        assert_equal "You are helpful", result[:system]
      end

      test "compress_content leaves multi-block content as array" do
        hash = {
          messages: [
            { role: "user", content: [
              { type: "text", text: "hello" },
              { type: "text", text: "world" }
            ] }
          ]
        }

        result =  transforms.compress_content(hash)

        assert result[:messages][0][:content].is_a?(Array)
        assert_equal 2, result[:messages][0][:content].size
      end

      test "compress_content returns non-hash input unchanged" do
        input = "not a hash"

        result =  transforms.compress_content(input)

        assert_equal "not a hash", result
      end

      # compress_message_content! tests
      test "compress_message_content! converts single text block to string" do
        msg = { content: [ { type: "text", text: "hello" } ] }

         transforms.compress_message_content!(msg)

        assert_equal "hello", msg[:content]
      end

      test "compress_message_content! leaves non-array content unchanged" do
        msg = { content: "hello" }

         transforms.compress_message_content!(msg)

        assert_equal "hello", msg[:content]
      end

      test "compress_message_content! leaves multi-block content unchanged" do
        msg = { content: [
          { type: "text", text: "hello" },
          { type: "text", text: "world" }
        ] }
        original = msg[:content].dup

         transforms.compress_message_content!(msg)

        assert_equal original, msg[:content]
      end

      test "compress_message_content! leaves non-text blocks unchanged" do
        msg = { content: [ { type: "image", source: { type: "url", url: "http://example.com" } } ] }
        original = msg[:content].dup

         transforms.compress_message_content!(msg)

        assert_equal original, msg[:content]
      end

      # cleanup_serialized_request tests
      test "cleanup_serialized_request removes response-only fields from messages" do
        hash = {
          messages: [
            { role: "assistant", content: "hello", id: "msg_123", model: "claude-3", stop_reason: "end_turn", type: "message", usage: { input_tokens: 10 } }
          ]
        }

        result =  transforms.cleanup_serialized_request(hash, {})

        assert_nil result[:messages][0][:id]
        assert_nil result[:messages][0][:model]
        assert_nil result[:messages][0][:stop_reason]
        assert_nil result[:messages][0][:type]
        assert_nil result[:messages][0][:usage]
        assert_equal "hello", result[:messages][0][:content]
      end

      test "cleanup_serialized_request compresses content" do
        hash = {
          messages: [
            { role: "user", content: [ { type: "text", text: "hello" } ] }
          ]
        }

        result =  transforms.cleanup_serialized_request(hash, {})

        assert_equal "hello", result[:messages][0][:content]
      end

      test "cleanup_serialized_request removes empty mcp_servers" do
        hash = { mcp_servers: [], model: "claude-3" }

        result =  transforms.cleanup_serialized_request(hash, {})

        assert_nil result[:mcp_servers]
        assert_equal "claude-3", result[:model]
      end

      test "cleanup_serialized_request keeps non-empty mcp_servers" do
        hash = {
          mcp_servers: [
            { type: "url", name: "stripe", url: "https://mcp.stripe.com" }
          ],
          model: "claude-3"
        }

        result = transforms.cleanup_serialized_request(hash, {})

        assert_not_nil result[:mcp_servers]
        assert_equal 1, result[:mcp_servers].length
        assert_equal "stripe", result[:mcp_servers][0][:name]
      end

      test "cleanup_serialized_request removes empty stop_sequences" do
        hash = { stop_sequences: [], model: "claude-3" }

        result =  transforms.cleanup_serialized_request(hash, {})

        assert_nil result[:stop_sequences]
      end

      test "cleanup_serialized_request removes default values except max_tokens" do
        defaults = { temperature: 1.0, top_p: 1.0, max_tokens: 4096 }
        hash = { temperature: 1.0, top_p: 0.9, max_tokens: 4096, model: "claude-3" }

        result =  transforms.cleanup_serialized_request(hash, defaults)

        assert_nil result[:temperature]
        assert_equal 0.9, result[:top_p]
        assert_equal 4096, result[:max_tokens] # Should not be removed
      end

      # Integration tests
      test "full message normalization with consecutive same-role messages" do
        messages = [
          { role: "user", content: "Hello" },
          { role: "user", content: "How are you?" },
          { role: "assistant", content: "I'm fine" },
          { role: "assistant", content: "Thanks for asking" }
        ]

        result =  transforms.normalize_messages(messages)

        assert_equal 2, result.size
        assert_equal :user, result[0][:role]
        assert_equal 2, result[0][:content].size
        assert_equal :assistant, result[1][:role]
        assert_equal 2, result[1][:content].size
      end

      test "full content normalization with mixed types" do
        content = {
          text: "Check this image",
          image: "http://example.com/image.jpg",
          document: "data:application/pdf;base64,JVBERi0xLjQ"
        }

        result =  transforms.normalize_content(content)

        assert_equal 3, result.size
        assert_equal "text", result[0][:type]
        assert_equal "image", result[1][:type]
        assert_equal "document", result[2][:type]
      end

      test "round-trip normalization and compression" do
        original = {
          messages: [
            { role: "user", content: "hello" }
          ],
          system: "You are helpful"
        }

        normalized =  transforms.normalize_params(original)
        compressed =  transforms.compress_content(normalized)

        assert_equal "hello", compressed[:messages][0][:content]
        assert_equal "You are helpful", compressed[:system]
      end

      # normalize_mcp_servers tests
      test "normalize_mcp_servers converts common format to Anthropic format" do
        mcp_servers = [
          {
            name: "stripe",
            url: "https://mcp.stripe.com",
            authorization: "sk_test_123"
          }
        ]

        result = transforms.normalize_mcp_servers(mcp_servers)

        assert_equal 1, result.size
        assert_equal "url", result[0][:type]
        assert_equal "stripe", result[0][:name]
        assert_equal "https://mcp.stripe.com", result[0][:url]
        assert_equal "sk_test_123", result[0][:authorization_token]
      end

      test "normalize_mcp_servers handles server without authorization" do
        mcp_servers = [
          {
            name: "public_api",
            url: "https://mcp.public.com"
          }
        ]

        result = transforms.normalize_mcp_servers(mcp_servers)

        assert_equal 1, result.size
        assert_equal "url", result[0][:type]
        assert_equal "public_api", result[0][:name]
        assert_equal "https://mcp.public.com", result[0][:url]
        assert_nil result[0][:authorization_token]
      end

      test "normalize_mcp_servers preserves Anthropic format without auth" do
        mcp_servers = [
          {
            type: "url",
            name: "stripe",
            url: "https://mcp.stripe.com"
          }
        ]

        result = transforms.normalize_mcp_servers(mcp_servers)

        assert_equal 1, result.size
        assert_equal "url", result[0][:type]
        assert_equal "stripe", result[0][:name]
        assert_equal "https://mcp.stripe.com", result[0][:url]
      end

      test "normalize_mcp_servers preserves Anthropic format with authorization_token" do
        mcp_servers = [
          {
            type: "url",
            name: "stripe",
            url: "https://mcp.stripe.com",
            authorization_token: "sk_test_123"
          }
        ]

        result = transforms.normalize_mcp_servers(mcp_servers)

        assert_equal 1, result.size
        assert_equal "url", result[0][:type]
        assert_equal "stripe", result[0][:name]
        assert_equal "https://mcp.stripe.com", result[0][:url]
        assert_equal "sk_test_123", result[0][:authorization_token]
      end

      test "normalize_mcp_servers converts common format with authorization to native" do
        mcp_servers = [
          {
            type: "url",
            name: "test",
            url: "https://test.com",
            authorization: "token123"  # Common format field, should be converted
          }
        ]

        result = transforms.normalize_mcp_servers(mcp_servers)

        assert_equal 1, result.size
        assert_equal "url", result[0][:type]
        assert_equal "test", result[0][:name]
        assert_equal "https://test.com", result[0][:url]
        assert_equal "token123", result[0][:authorization_token]
        assert_nil result[0][:authorization]  # Should not have common format field
      end

      test "normalize_mcp_servers handles multiple servers" do
        mcp_servers = [
          {
            name: "stripe",
            url: "https://mcp.stripe.com",
            authorization: "key1"
          },
          {
            name: "sendgrid",
            url: "https://mcp.sendgrid.com",
            authorization: "key2"
          }
        ]

        result = transforms.normalize_mcp_servers(mcp_servers)

        assert_equal 2, result.size
        assert_equal "stripe", result[0][:name]
        assert_equal "sendgrid", result[1][:name]
        assert_equal "key1", result[0][:authorization_token]
        assert_equal "key2", result[1][:authorization_token]
      end

      test "normalize_mcp_servers accepts authorization_token directly" do
        mcp_servers = [
          {
            name: "test",
            url: "https://test.com",
            authorization_token: "token123"
          }
        ]

        result = transforms.normalize_mcp_servers(mcp_servers)

        assert_equal "token123", result[0][:authorization_token]
      end

      test "normalize_mcp_servers returns nil for nil input" do
        result = transforms.normalize_mcp_servers(nil)

        assert_nil result
      end

      test "normalize_mcp_servers returns non-array unchanged" do
        result = transforms.normalize_mcp_servers("not an array")

        assert_equal "not an array", result
      end
    end
  end
end
