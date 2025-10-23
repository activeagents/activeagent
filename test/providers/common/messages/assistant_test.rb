# frozen_string_literal: true

require "test_helper"
require "active_agent/providers/common/messages/assistant"

module ActiveAgent
  module Providers
    module Common
      module Messages
        class AssistantTest < ActiveSupport::TestCase
          test "json_object parses valid JSON with default options" do
            json_content = '{"firstName": "John", "lastName": "Doe"}'
            assistant_message =  ActiveAgent::Providers::Common::Messages::Assistant.new(content: json_content)

            result = assistant_message.json_object

            assert_not_nil result
            # Default: symbolize_names: true, normalize_names: :underscore
            assert result.key?(:first_name)
            assert result.key?(:last_name)
            assert_equal "John", result[:first_name]
            assert_equal "Doe", result[:last_name]
          end

          test "json_object with symbolize_names: false returns string keys" do
            json_content = '{"firstName": "John", "lastName": "Doe"}'
            assistant_message = ActiveAgent::Providers::Common::Messages::Assistant.new(content: json_content)

            result = assistant_message.json_object(symbolize_names: false)

            assert_not_nil result
            assert result.key?("first_name")
            assert result.key?("last_name")
            assert_not result.key?(:first_name)
          end

          test "json_object with normalize_names: false preserves original keys" do
            json_content = '{"firstName": "John", "lastName": "Doe"}'
            assistant_message = ActiveAgent::Providers::Common::Messages::Assistant.new(content: json_content)

            result = assistant_message.json_object(normalize_names: false)

            assert_not_nil result
            assert result.key?(:firstName)
            assert result.key?(:lastName)
            assert_not result.key?(:first_name)
          end

          test "json_object with both options false preserves original format" do
            json_content = '{"firstName": "John", "lastName": "Doe"}'
            assistant_message = ActiveAgent::Providers::Common::Messages::Assistant.new(content: json_content)

            result = assistant_message.json_object(symbolize_names: false, normalize_names: false)

            assert_not_nil result
            assert result.key?("firstName")
            assert result.key?("lastName")
            assert_equal "John", result["firstName"]
          end

          test "json_object handles nested JSON with normalization" do
            json_content = '{"assistantProfile": {"firstName": "Jane", "homeAddress": {"streetName": "Main St"}}}'
            assistant_message = ActiveAgent::Providers::Common::Messages::Assistant.new(content: json_content)

            result = assistant_message.json_object

            assert_not_nil result
            assert result.key?(:assistant_profile)
            assert result[:assistant_profile].key?(:first_name)
            assert result[:assistant_profile][:home_address].key?(:street_name)
            assert_equal "Main St", result[:assistant_profile][:home_address][:street_name]
          end

          test "json_object returns nil for invalid JSON" do
            invalid_json = "This is not JSON {invalid}"
            assistant_message = ActiveAgent::Providers::Common::Messages::Assistant.new(content: invalid_json)

            result = assistant_message.json_object

            assert_nil result
          end

          test "json_object returns nil for plain text content" do
            plain_text = "Just a regular message"
            assistant_message = ActiveAgent::Providers::Common::Messages::Assistant.new(content: plain_text)

            result = assistant_message.json_object

            assert_nil result
          end

          test "json_object handles empty JSON object" do
            json_content = "{}"
            assistant_message = ActiveAgent::Providers::Common::Messages::Assistant.new(content: json_content)

            result = assistant_message.json_object

            assert_not_nil result
            assert_equal({}, result)
          end

          test "json_object handles JSON array" do
            json_content = '[{"firstName": "John"}, {"firstName": "Jane"}]'
            assistant_message = ActiveAgent::Providers::Common::Messages::Assistant.new(content: json_content)

            result = assistant_message.json_object

            assert_not_nil result
            assert_equal 2, result.size
            assert_equal "John", result[0][:first_name]
            assert_equal "Jane", result[1][:first_name]
          end

          test "json_object handles text at start of message" do
            json_content = 'Here is the JSON requested:\n{"firstName": "John", "lastName": "Doe"}'
            assistant_message = ActiveAgent::Providers::Common::Messages::Assistant.new(content: json_content)

            result = assistant_message.json_object

            assert_not_nil result
            assert_equal "John", result[:first_name]
            assert_equal "Doe", result[:last_name]
          end

          test "json_object handles text at end of message" do
            json_content = '{"firstName": "John", "lastName": "Doe"}\nThank you!'
            assistant_message = ActiveAgent::Providers::Common::Messages::Assistant.new(content: json_content)

            result = assistant_message.json_object

            assert_not_nil result
            assert_equal "John", result[:first_name]
            assert_equal "Doe", result[:last_name]
          end

          test "json_object handles text around message" do
            json_content = 'Here is the JSON requested:\n{"firstName": "John", "lastName": "Doe"}\nThank you!'
            assistant_message = ActiveAgent::Providers::Common::Messages::Assistant.new(content: json_content)

            result = assistant_message.json_object

            assert_not_nil result
            assert_equal "John", result[:first_name]
            assert_equal "Doe", result[:last_name]
          end
        end
      end
    end
  end
end
