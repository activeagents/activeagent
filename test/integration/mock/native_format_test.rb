# frozen_string_literal: true

require_relative "test_helper"

module Integration
  module Mock
    class NativeFormatTest < ActiveSupport::TestCase
      include Integration::Mock::TestHelper

      class TestAgent < ActiveAgent::Base
        generate_with :mock

        ###############################################################
        # Basic Request
        ###############################################################
        BASIC_REQUEST = {
          "model": "mock-model",
          "messages": [
            {
              "role": "user",
              "content": "Hello, Mock!"
            }
          ]
        }
        def basic_request
          prompt(
            messages: [
              { role: "user", content: "Hello, Mock!" }
            ]
          )
        end

        ###############################################################
        # Request with Temperature
        ###############################################################
        TEMPERATURE_REQUEST = {
          "model": "mock-model",
          "messages": [
            {
              "role": "user",
              "content": "What is 2+2?"
            }
          ],
          "temperature": 0.7
        }
        def temperature_request
          prompt(
            messages: [
              { role: "user", content: "What is 2+2?" }
            ],
            temperature: 0.7
          )
        end

        ###############################################################
        # Request with Max Tokens
        ###############################################################
        MAX_TOKENS_REQUEST = {
          "model": "mock-model",
          "messages": [
            {
              "role": "user",
              "content": "Tell me a story"
            }
          ],
          "max_tokens": 100
        }
        def max_tokens_request
          prompt(
            messages: [
              { role: "user", content: "Tell me a story" }
            ],
            max_tokens: 100
          )
        end

        ###############################################################
        # Multiple Messages
        ###############################################################
        MULTIPLE_MESSAGES = {
          "model": "mock-model",
          "messages": [
            {
              "role": "user",
              "content": "Hello!"
            },
            {
              "role": "assistant",
              "content": "Hi there! How can I help you?"
            },
            {
              "role": "user",
              "content": "What's the weather like?"
            }
          ]
        }
        def multiple_messages
          prompt(
            messages: [
              { role: "user", content: "Hello!" },
              { role: "assistant", content: "Hi there! How can I help you?" },
              { role: "user", content: "What's the weather like?" }
            ]
          )
        end

        ###############################################################
        # User Message with Content Blocks
        ###############################################################
        USER_MESSAGE_CONTENT_BLOCKS = {
          "model": "mock-model",
          "messages": [
            {
              "role": "user",
              "content": [
                {
                  "type": "text",
                  "text": "Hello"
                },
                {
                  "type": "text",
                  "text": "World"
                }
              ]
            }
          ]
        }
        def user_message_content_blocks
          prompt(
            messages: [
              {
                role: "user",
                content: [
                  {
                    type: "text",
                    text: "Hello"
                  },
                  {
                    type: "text",
                    text: "World"
                  }
                ]
              }
            ]
          )
        end

        ###############################################################
        # Streaming
        ###############################################################
        STREAMING = {
          "model": "mock-model",
          "messages": [
            {
              "role": "user",
              "content": "Tell me a short story"
            }
          ],
          "stream": true
        }
        def streaming
          prompt(
            messages: [
              { role: "user", content: "Tell me a short story" }
            ],
            stream: true
          )
        end

        ###############################################################
        # Sampling Parameters
        ###############################################################
        SAMPLING_PARAMETERS = {
          "model": "mock-model",
          "messages": [
            {
              "role": "user",
              "content": "Generate creative text"
            }
          ],
          "temperature": 0.8,
          "max_tokens": 200
        }
        def sampling_parameters
          prompt(
            messages: [
              { role: "user", content: "Generate creative text" }
            ],
            temperature: 0.8,
            max_tokens: 200
          )
        end
      end

      ################################################################################
      # This automatically runs all the tests for these the test actions
      ################################################################################
      [
        :basic_request,
        :temperature_request,
        :max_tokens_request,
        :multiple_messages,
        :user_message_content_blocks,
        :streaming,
        :sampling_parameters
      ].each do |action_name|
        test_request_builder(TestAgent, action_name, :generate_now, TestAgent.const_get(action_name.to_s.upcase, true))
      end
    end
  end
end
