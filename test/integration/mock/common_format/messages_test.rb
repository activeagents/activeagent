# frozen_string_literal: true

require_relative "../test_helper"

module Integration
  module Mock
    module CommonFormat
      class MessagesTest < ActiveSupport::TestCase
        include Integration::Mock::TestHelper

        # Note: MockProvider doesn't support image/document attachments
        # So we'll test text-based messages only

        class TestAgent < ActiveAgent::Base
          generate_with :mock

          TEMPLATES_DEFAULT = {
            model: "mock-model",
            messages: [
              {
                role: "user",
                content: "What is the capital of France?"
              }
            ]
          }
          def templates_default
            prompt
          end

          TEMPLATES_WITH_LOCALS = {
            model: "mock-model",
            messages: [
              {
                role: "user",
                content: "Tell me about Japan and its capital city Tokyo."
              }
            ]
          }
          def templates_with_locals
            prompt(locals: { country: "Japan", capital: "Tokyo" })
          end

          TEXT_BARE = {
            model: "mock-model",
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
            model: "mock-model",
            messages: [
              {
                role: "user",
                content: "Explain quantum computing in bare terms."
              }
            ]
          }
          def text_message_bare
            prompt(message: "Explain quantum computing in bare terms.")
          end

          TEXT_MESSAGE_OBJECT = {
            model: "mock-model",
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

          TEXTS_BARE = {
            model: "mock-model",
            messages: [
              {
                role: "user",
                content: "Tell me a fun fact about Ruby programming."
              },
              {
                role: "user",
                content: "Now explain why that's interesting."
              }
            ]
          }
          def texts_bare
            prompt(
              "Tell me a fun fact about Ruby programming.",
              "Now explain why that's interesting."
            )
          end

          TEXT_MESSAGES_BARE = {
            model: "mock-model",
            messages: [
              {
                role: "user",
                content: "Tell me a fun fact about Ruby programming."
              },
              {
                role: "user",
                content: "Now explain why that's interesting."
              }
            ]
          }
          def text_messages_bare
            prompt(messages: [
              "Tell me a fun fact about Ruby programming.",
              "Now explain why that's interesting."
            ])
          end

          TEXT_MESSAGES_OBJECT = {
            model: "mock-model",
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

        ################################################################################
        # This automatically runs all the tests for the test actions
        ################################################################################
        [
          # Template tests
          :templates_default,
          :templates_with_locals,

          # Text Test
          :text_bare,
          :text_message_bare,
          :text_message_object,
          :texts_bare,
          :text_messages_bare,
          :text_messages_object
        ].each do |action_name|
          test_request_builder(TestAgent, action_name, :generate_now, TestAgent.const_get(action_name.to_s.upcase, true))
        end
      end
    end
  end
end
