# frozen_string_literal: true

require_relative "../../test_helper"

module Integration
  module Azure
    module CommonFormat
      class InstructionsTest < ActiveSupport::TestCase
        include Integration::TestHelper

        class TestAgent < ActiveAgent::Base
          generate_with :azure_openai,
            api_key: ENV["AZURE_OPENAI_API_KEY"],
            azure_resource: ENV["AZURE_OPENAI_RESOURCE"],
            deployment_id: ENV["AZURE_OPENAI_DEPLOYMENT_ID"],
            model: ENV.fetch("AZURE_OPENAI_MODEL", "gpt-4")

          # Single instruction as string
          def single_instruction
            prompt(
              instructions: "You are a helpful assistant that speaks like a pirate.",
              message: "What is the capital of France?"
            )
          end

          # Multiple instructions as array
          def multiple_instructions
            prompt(
              instructions: [
                "You are a helpful assistant.",
                "Always respond in exactly 3 words."
              ],
              message: "What is 2+2?"
            )
          end

          # System message with user message
          def system_with_user
            prompt(
              messages: [
                { role: "system", content: "You are a code reviewer. Be concise." },
                { role: "user", content: "Review this: puts 'hello'" }
              ]
            )
          end

          # Developer message (OpenAI-style system)
          def developer_message
            prompt(
              messages: [
                { role: "developer", content: "Respond only with JSON." },
                { role: "user", content: "List 3 colours" }
              ]
            )
          end
        end

        setup do
          skip "Azure OpenAI credentials not configured" unless has_azure_openai_credentials?
        end

        test "single instruction is applied to response" do
          VCR.use_cassette("integration/azure/common_format/instructions_test/single_instruction") do
            response = TestAgent.single_instruction.generate_now

            assert response.success?
            assert_not_nil response.message.content
            # Should mention Paris and possibly have pirate-speak
            content = response.message.content.downcase
            assert_includes content, "paris"
          end
        end

        test "multiple instructions are applied" do
          VCR.use_cassette("integration/azure/common_format/instructions_test/multiple_instructions") do
            response = TestAgent.multiple_instructions.generate_now

            assert response.success?
            assert_not_nil response.message.content
          end
        end

        test "system message sets context" do
          VCR.use_cassette("integration/azure/common_format/instructions_test/system_with_user") do
            response = TestAgent.system_with_user.generate_now

            assert response.success?
            assert_not_nil response.message.content
          end
        end

        test "developer message works as system" do
          VCR.use_cassette("integration/azure/common_format/instructions_test/developer_message") do
            response = TestAgent.developer_message.generate_now

            assert response.success?
            assert_not_nil response.message.content
          end
        end
      end
    end
  end
end
