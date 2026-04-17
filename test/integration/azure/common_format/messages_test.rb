# frozen_string_literal: true

require_relative "../../test_helper"

module Integration
  module Azure
    module CommonFormat
      class MessagesTest < ActiveSupport::TestCase
        include Integration::TestHelper

        class TestAgent < ActiveAgent::Base
          generate_with :azure_openai,
            api_key: ENV["AZURE_OPENAI_API_KEY"],
            azure_resource: ENV["AZURE_OPENAI_RESOURCE"],
            deployment_id: ENV["AZURE_OPENAI_DEPLOYMENT_ID"],
            model: ENV.fetch("AZURE_OPENAI_MODEL", "gpt-4")

          TEXT_BARE = {
            model: ENV.fetch("AZURE_OPENAI_MODEL", "gpt-4"),
            messages: [
              {
                role: "user",
                content: "What is the capital of France?"
              }
            ]
          }
          def text_bare
            prompt("What is the capital of France?")
          end

          TEXT_MESSAGE_BARE = {
            model: ENV.fetch("AZURE_OPENAI_MODEL", "gpt-4"),
            messages: [
              {
                role: "user",
                content: "Explain quantum computing in simple terms."
              }
            ]
          }
          def text_message_bare
            prompt(message: "Explain quantum computing in simple terms.")
          end

          TEXT_MESSAGE_OBJECT = {
            model: ENV.fetch("AZURE_OPENAI_MODEL", "gpt-4"),
            messages: [
              {
                role: "user",
                content: "What are the main differences between Ruby and Python?"
              }
            ]
          }
          def text_message_object
            prompt(message: { text: "What are the main differences between Ruby and Python?" })
          end

          TEXT_MESSAGES_OBJECT = {
            model: ENV.fetch("AZURE_OPENAI_MODEL", "gpt-4"),
            messages: [
              {
                role: "assistant",
                content: "I can help you with programming questions."
              },
              {
                role: "user",
                content: "What are the benefits of using ActiveRecord?"
              }
            ]
          }
          def text_messages_object
            prompt(messages: [
              {
                role: "assistant",
                text: "I can help you with programming questions."
              },
              {
                text: "What are the benefits of using ActiveRecord?"
              }
            ])
          end
        end

        setup do
          skip "Azure OpenAI credentials not configured" unless has_azure_openai_credentials?
        end

        test "text_bare creates correct request and returns response" do
          VCR.use_cassette("integration/azure/common_format/messages_test/text_bare") do
            response = TestAgent.text_bare.generate_now

            assert response.success?
            assert_not_nil response.message.content
            # Should mention Paris
            assert_includes response.message.content.downcase, "paris"
          end
        end

        test "text_message_bare creates correct request and returns response" do
          VCR.use_cassette("integration/azure/common_format/messages_test/text_message_bare") do
            response = TestAgent.text_message_bare.generate_now

            assert response.success?
            assert_not_nil response.message.content
          end
        end

        test "text_message_object creates correct request and returns response" do
          VCR.use_cassette("integration/azure/common_format/messages_test/text_message_object") do
            response = TestAgent.text_message_object.generate_now

            assert response.success?
            assert_not_nil response.message.content
          end
        end

        test "text_messages_object preserves conversation context" do
          VCR.use_cassette("integration/azure/common_format/messages_test/text_messages_object") do
            response = TestAgent.text_messages_object.generate_now

            assert response.success?
            assert_not_nil response.message.content
          end
        end
      end
    end
  end
end
