# frozen_string_literal: true

require_relative "../../../test_helper"

module Integration
  module OpenAI
    module Responses
      module CommonFormat
        class InstructionsTest < ActiveSupport::TestCase
          include Integration::TestHelper

          # Case 1: Agent without instructions (no instructions set in test agent)
          class NoInstructionsAgent < ActiveAgent::Base
            generate_with :openai, model: "gpt-4.1"

            BASIC_REQUEST = {
              "model": "gpt-4.1",
              "input": "Hello, GPT!"
            }

            def basic_request
              prompt(input: "Hello, GPT!")
            end

            BASIC_REQUEST_WITH_OVERRIDE = {
              "model": "gpt-4.1",
              "instructions": "You are an overridden assistant.",
              "input": "Hello, GPT!"
            }

            def basic_request_with_override
              prompt(
                instructions: "You are an overridden assistant.",
                input: "Hello, GPT!"
              )
            end
          end

          # Case 2: Agent auto loads instructions from template (no instructions set in Test Agent, looked by name)
          class AutoTemplateAgent < ActiveAgent::Base
            generate_with :openai, model: "gpt-4.1"

            BASIC_REQUEST = {
              "model": "gpt-4.1",
              "instructions": "Default auto-loaded instructions for testing.",
              "input": "Hello, GPT!"
            }

            def basic_request
              prompt(input: "Hello, GPT!")
            end

            BASIC_REQUEST_WITH_OVERRIDE = {
              "model": "gpt-4.1",
              "instructions": "You are an overridden assistant.",
              "input": "Hello, GPT!"
            }

            def basic_request_with_override
              prompt(
                instructions: "You are an overridden assistant.",
                input: "Hello, GPT!"
              )
            end
          end

          # Case 3: Agent has instructions set via generate_with instructions:
          class ConfiguredInstructionsAgent < ActiveAgent::Base
            generate_with :openai,
                          model: "gpt-4.1",
                          instructions: "You are a configured assistant with default instructions."

            BASIC_REQUEST = {
              "model": "gpt-4.1",
              "instructions": "You are a configured assistant with default instructions.",
              "input": "Hello, GPT!"
            }

            def basic_request
              prompt(input: "Hello, GPT!")
            end

            BASIC_REQUEST_WITH_OVERRIDE = {
              "model": "gpt-4.1",
              "instructions": "You are an overridden assistant.",
              "input": "Hello, GPT!"
            }

            def basic_request_with_override
              prompt(
                instructions: "You are an overridden assistant.",
                input: "Hello, GPT!"
              )
            end
          end

          # Case 4: Agent with array of system instructions
          class ArrayInstructionsAgent < ActiveAgent::Base
            generate_with :openai,
                          model: "gpt-4.1",
                          instructions: [ "You are a helpful assistant.", "Always be polite and professional." ]

            BASIC_REQUEST = {
              "model": "gpt-4.1",
              "instructions": "You are a helpful assistant.\nAlways be polite and professional.",
              "input": "Hello, GPT!"
            }

            def basic_request
              prompt(input: "Hello, GPT!")
            end

            BASIC_REQUEST_WITH_OVERRIDE = {
              "model": "gpt-4.1",
              "instructions": "You are an overridden assistant.\nPlease respond concisely.",
              "input": "Hello, GPT!"
            }

            def basic_request_with_override
              prompt(
                instructions: [ "You are an overridden assistant.", "Please respond concisely." ],
                input: "Hello, GPT!"
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
