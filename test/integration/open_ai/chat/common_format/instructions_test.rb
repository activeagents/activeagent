# frozen_string_literal: true

require_relative "../../../test_helper"

module Integration
  module OpenAI
    module Chat
      module CommonFormat
        class InstructionsTest < ActiveSupport::TestCase
          include Integration::TestHelper

        # Case 1: Agent without instructions (no instructions set in test agent)
        class NoInstructionsAgent < ActiveAgent::Base
          generate_with :openai, model: "gpt-5", api_version: :chat

          BASIC_REQUEST = {
            "model": "gpt-5",
            "messages": [
              {
                "role": "user",
                "content": "Hello, GPT!"
              }
            ]
          }

          def basic_request
            prompt(
              messages: [
                { role: "user", content: "Hello, GPT!" }
              ]
            )
          end

          BASIC_REQUEST_WITH_OVERRIDE = {
            "model": "gpt-5",
            "messages": [
              {
                "role": "developer",
                "content": "You are an overridden assistant."
              },
              {
                "role": "user",
                "content": "Hello, GPT!"
              }
            ]
          }

          def basic_request_with_override
            prompt(
              instructions: "You are an overridden assistant.",
              messages: [
                { role: "user", content: "Hello, GPT!" }
              ]
            )
          end
        end

        # Case 2: Agent auto loads instructions from template (no instructions set in Test Agent, looked by name)
        class AutoTemplateAgent < ActiveAgent::Base
          generate_with :openai, model: "gpt-5", api_version: :chat

          BASIC_REQUEST = {
            "model": "gpt-5",
            "messages": [
              {
                "role": "developer",
                "content": "Default auto-loaded instructions for testing."
              },
              {
                "role": "user",
                "content": "Hello, GPT!"
              }
            ]
          }

          def basic_request
            prompt(
              messages: [
                { role: "user", content: "Hello, GPT!" }
              ]
            )
          end

          BASIC_REQUEST_WITH_OVERRIDE = {
            "model": "gpt-5",
            "messages": [
              {
                "role": "developer",
                "content": "You are an overridden assistant."
              },
              {
                "role": "user",
                "content": "Hello, GPT!"
              }
            ]
          }

          def basic_request_with_override
            prompt(
              instructions: "You are an overridden assistant.",
              messages: [
                { role: "user", content: "Hello, GPT!" }
              ]
            )
          end
        end

        # Case 3: Agent has instructions set via generate_with instructions:
        class ConfiguredInstructionsAgent < ActiveAgent::Base
          generate_with :openai,
                        model: "gpt-5",
                        api_version: :chat,
                        instructions: "You are a configured assistant with default instructions."

          BASIC_REQUEST = {
            "model": "gpt-5",
            "messages": [
              {
                "role": "developer",
                "content": "You are a configured assistant with default instructions."
              },
              {
                "role": "user",
                "content": "Hello, GPT!"
              }
            ]
          }

          def basic_request
            prompt(
              messages: [
                { role: "user", content: "Hello, GPT!" }
              ]
            )
          end

          BASIC_REQUEST_WITH_OVERRIDE = {
            "model": "gpt-5",
            "messages": [
              {
                "role": "developer",
                "content": "You are an overridden assistant."
              },
              {
                "role": "user",
                "content": "Hello, GPT!"
              }
            ]
          }

          def basic_request_with_override
            prompt(
              instructions: "You are an overridden assistant.",
              messages: [
                { role: "user", content: "Hello, GPT!" }
              ]
            )
          end
        end

        # Case 4: Agent with array of system instructions
        class ArrayInstructionsAgent < ActiveAgent::Base
          generate_with :openai,
                        model: "gpt-5",
                        api_version: :chat,
                        instructions: [ "You are a helpful assistant.", "Always be polite and professional." ]

          BASIC_REQUEST = {
            "model": "gpt-5",
            "messages": [
              {
                "role": "developer",
                "content": "You are a helpful assistant."
              },
              {
                "role": "developer",
                "content": "Always be polite and professional."
              },
              {
                "role": "user",
                "content": "Hello, GPT!"
              }
            ]
          }

          def basic_request
            prompt(
              messages: [
                { role: "user", content: "Hello, GPT!" }
              ]
            )
          end

          BASIC_REQUEST_WITH_OVERRIDE = {
            "model": "gpt-5",
            "messages": [
              {
                "role": "developer",
                "content": "You are an overridden assistant."
              },
              {
                "role": "developer",
                "content": "Please respond concisely."
              },
              {
                "role": "user",
                "content": "Hello, GPT!"
              }
            ]
          }

          def basic_request_with_override
            prompt(
              instructions: [ "You are an overridden assistant.", "Please respond concisely." ],
              messages: [
                { role: "user", content: "Hello, GPT!" }
              ]
            )
          end
        end

        ################################################################################
        # This automatically runs all the tests for these the test actions
        ################################################################################
        [
          # Case 1: No instructions agent
          [ NoInstructionsAgent, :basic_request ],
          [ NoInstructionsAgent, :basic_request_with_override ],

          # Case 2: Auto template agent (loads instructions from template by name)
          [ AutoTemplateAgent, :basic_request ],
          [ AutoTemplateAgent, :basic_request_with_override ],

          # Case 3: Configured instructions agent
          [ ConfiguredInstructionsAgent, :basic_request ],
          [ ConfiguredInstructionsAgent, :basic_request_with_override ],

          # Case 4: Array instructions agent
          [ ArrayInstructionsAgent, :basic_request ],
          [ ArrayInstructionsAgent, :basic_request_with_override ]
        ].each do |agent_class, action_name|
          test_request_builder(agent_class, action_name, :generate_now)
        end
        end
      end
    end
  end
end
