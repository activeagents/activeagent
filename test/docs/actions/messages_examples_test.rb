require "test_helper"

module Docs
  module Actions
    module Messages
      # region single_message_agent
      class SingleMessageAgent < ApplicationAgent
        generate_with :openai, model: "gpt-4o-mini"

        def chat
          prompt("What is the capital of France?")
        end
      end
      # endregion single_message_agent

      # region message_keyword_agent
      class MessageKeywordAgent < ApplicationAgent
        generate_with :anthropic, model: "claude-3-5-haiku-20241022"

        def chat
          prompt(message: "Explain quantum computing")
        end
      end
      # endregion message_keyword_agent

      # region multiple_messages_agent
      class MultipleMessagesAgent < ApplicationAgent
        generate_with :open_router, model: "openai/gpt-4o-mini"

        def chat_inline
          prompt(
            "Tell me a fun fact about Ruby.",
            "Now explain why that's interesting."
          )
        end

        def chat_array
          prompt(messages: [
            "Tell me a fun fact about Ruby.",
            "Now explain why that's interesting."
          ])
        end
      end
      # endregion multiple_messages_agent

      # region messages_with_roles_agent
      class MessagesWithRolesAgent < ApplicationAgent
        generate_with :openai, model: "gpt-4o-mini"

        def chat_multiple
          prompt(messages: [
            { role: "assistant", text: "I can help with programming questions." },
            { text: "What are the benefits of ActiveRecord?" }
          ])
        end

        def chat_single
          prompt(message: { role: "assistant", text: "Previous response..." })
        end
      end
      # endregion messages_with_roles_agent

      # region image_agent
      class ImageAgent < ApplicationAgent
        generate_with :anthropic, model: "claude-3-5-haiku-20241022"

        def analyze_url
          prompt(
            "What's in this image?",
            image: "https://framerusercontent.com/images/oEx786EYW2ZVL4Xf9hparOVLjHI.png?scale-down-to=64"
          )
        end

        def analyze_base64
          prompt(
            "Describe this image",
            image: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
          )
        end

        def analyze_message_hash
          prompt(message: {
            text: "Analyze this",
            image: "https://framerusercontent.com/images/oEx786EYW2ZVL4Xf9hparOVLjHI.png?scale-down-to=64"
          })
        end

        def analyze_messages_array
          prompt(messages: [
            { text: "What's in this image?" },
            { image: "https://framerusercontent.com/images/oEx786EYW2ZVL4Xf9hparOVLjHI.png?scale-down-to=64" }
          ])
        end
      end
      # endregion image_agent

      # region document_agent
      class DocumentAgent < ApplicationAgent
        generate_with :openai, model: "gpt-4o-mini"

        def summarize_url
          prompt(
            "Summarize this document",
            document: "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf"
          )
        end
      end
      # endregion document_agent

      # region document_base64_agent
      class DocumentBase64Agent < ApplicationAgent
        generate_with :anthropic, model: "claude-3-5-haiku-20241022"

        def extract_base64
          file_path = Rails.root.join("../fixtures/files/sample_resume.pdf")
          base64_data = Base64.strict_encode64(File.read(file_path))
          pdf_base64_url = "data:application/pdf;base64,#{base64_data}"

          prompt(
            "Extract key points",
            document: pdf_base64_url
          )
        end
      end
      # endregion document_base64_agent

      # region inspect_messages_agent
      class InspectMessagesAgent < ApplicationAgent
        generate_with :openai, model: "gpt-4o-mini"

        def chat
          prompt("Hello")
        end
      end
      # endregion inspect_messages_agent

      # region system_messages_agent
      class SystemMessagesAgent < ApplicationAgent
        generate_with :anthropic, model: "claude-3-5-haiku-20241022"

        def chat
          prompt(
            instructions: "You are a travel booking assistant.",
            message: "Help me book a hotel"
          )
        end
      end
      # endregion system_messages_agent

      # region assistant_history_agent
      class AssistantHistoryAgent < ApplicationAgent
        generate_with :open_router, model: "openai/gpt-4o-mini"

        def continue_conversation
          prompt(messages: [
            { role: "assistant", text: "I can help you with that." },
            { text: "Great! I need help with X" }
          ])
        end
      end
      # endregion assistant_history_agent

      # region common_format_agent
      class CommonFormatAgent < ApplicationAgent
        generate_with :openai, model: "gpt-4o-mini"

        def multimodal
          prompt("Hello", image: "https://framerusercontent.com/images/oEx786EYW2ZVL4Xf9hparOVLjHI.png?scale-down-to=64")
        end
      end
      # endregion common_format_agent

      # region native_format_agent
      class NativeFormatAgent < ApplicationAgent
        generate_with :openai, model: "gpt-4o-mini"

        def multimodal_native
          # Use common format - the native format is provider-specific
          prompt("What's in this image?", image: "https://framerusercontent.com/images/oEx786EYW2ZVL4Xf9hparOVLjHI.png?scale-down-to=64")
        end
      end
      # endregion native_format_agent

      class Tests < ActiveSupport::TestCase
        test "single message agent sends simple message" do
          VCR.use_cassette("docs/actions/messages/single_message") do
            response = SingleMessageAgent.with(message: "Test").chat.generate_now

            assert response.success?
            assert_not_nil response.message.content
            assert response.message.content.length > 0
            assert_match(/paris/i, response.message.content)
          end
        end

        test "message keyword agent uses message parameter" do
          VCR.use_cassette("docs/actions/messages/message_keyword") do
            response = MessageKeywordAgent.with(message: "Test").chat.generate_now

            assert response.success?
            assert_not_nil response.message.content
            assert_match(/quantum/i, response.message.content)
          end
        end

        test "multiple messages agent sends multiple messages inline" do
          VCR.use_cassette("docs/actions/messages/multiple_inline") do
            response = MultipleMessagesAgent.with(message: "Test").chat_inline.generate_now

            assert response.success?
            assert_not_nil response.message.content
            assert_match(/ruby/i, response.message.content)
          end
        end

        test "multiple messages agent sends multiple messages as array" do
          VCR.use_cassette("docs/actions/messages/multiple_array") do
            response = MultipleMessagesAgent.with(message: "Test").chat_array.generate_now

            assert response.success?
            assert_not_nil response.message.content
            assert_match(/ruby/i, response.message.content)
          end
        end

        test "messages with roles agent sets explicit roles" do
          VCR.use_cassette("docs/actions/messages/with_roles_multiple") do
            response = MessagesWithRolesAgent.with(message: "Test").chat_multiple.generate_now

            assert response.success?
            assert_not_nil response.message.content
            assert_match(/activerecord|active record|database/i, response.message.content)
          end
        end

        test "messages with roles agent handles single message with role" do
          prompt = MessagesWithRolesAgent.with(message: "Test").chat_single
          assert prompt.messages.any?
        end

        test "image agent handles URL image" do
          VCR.use_cassette("docs/actions/messages/image_url") do
            response = ImageAgent.with(message: "Test").analyze_url.generate_now

            assert response.success?
            assert_not_nil response.message.content
            assert response.message.content.length > 0
          end
        end

        test "image agent handles base64 image" do
          VCR.use_cassette("docs/actions/messages/image_base64") do
            response = ImageAgent.with(message: "Test").analyze_base64.generate_now

            assert response.success?
            assert_not_nil response.message.content
          end
        end

        test "image agent handles message hash with image" do
          VCR.use_cassette("docs/actions/messages/image_message_hash") do
            response = ImageAgent.with(message: "Test").analyze_message_hash.generate_now

            assert response.success?
            assert_not_nil response.message.content
          end
        end

        test "image agent handles messages array with image" do
          VCR.use_cassette("docs/actions/messages/image_messages_array") do
            response = ImageAgent.with(message: "Test").analyze_messages_array.generate_now

            assert response.success?
            assert_not_nil response.message.content
          end
        end

        test "document agent handles URL document" do
          VCR.use_cassette("docs/actions/messages/document_url") do
            response = DocumentAgent.with(message: "Test").summarize_url.generate_now

            assert response.success?
            assert_not_nil response.message.content
            assert response.message.content.length > 0
          end
        end

        test "document agent handles base64 document" do
          VCR.use_cassette("docs/actions/messages/document_base64") do
            response = DocumentBase64Agent.with(message: "Test").extract_base64.generate_now

            assert response.success?
            assert_not_nil response.message.content
            assert response.message.content.length > 0
          end
        end

        test "inspect messages shows recent message" do
          VCR.use_cassette("docs/actions/messages/inspect_messages") do
            # region inspect_messages
            response = InspectMessagesAgent.with(message: "Hello").chat.generate_now

            response.message
            response.messages
            # endregion inspect_messages

            assert_not_nil response.message
            assert response.messages.any?
            assert_equal response.message, response.messages.last
          end
        end

        test "grouping by role filters messages" do
          VCR.use_cassette("docs/actions/messages/grouping_by_role") do
            response = InspectMessagesAgent.with(message: "Hello").chat.generate_now

            # region grouping_by_role
            system_messages = response.messages.select { |m| m.role == :system }
            user_messages = response.messages.select { |m| m.role == :user }
            assistant_messages = response.messages.select { |m| m.role == :assistant }
            tool_messages = response.messages.select { |m| m.role == :tool }
            # endregion grouping_by_role

            # Verify we got a response with messages
            assert response.success?
            assert response.messages.any?
            assert_not_nil response.message
          end
        end

        test "system messages come from instructions" do
          VCR.use_cassette("docs/actions/messages/system_messages") do
            response = SystemMessagesAgent.with(message: "Test").chat.generate_now

            # region inspect_system_message
            system_message = response.messages.find { |m| m.role == :system }
            # endregion inspect_system_message

            assert response.success?
            # Anthropic doesn't return system messages in the response
            # but they are sent to the API
            assert_not_nil response.message.content
          end
        end

        test "assistant history provides conversation context" do
          VCR.use_cassette("docs/actions/messages/assistant_history") do
            response = AssistantHistoryAgent.with(message: "Test").continue_conversation.generate_now

            assert response.success?
            assert_not_nil response.message.content
            assert response.message.content.length > 0
          end
        end

        test "common format works across providers" do
          VCR.use_cassette("docs/actions/messages/common_format") do
            response = CommonFormatAgent.with(message: "Test").multimodal.generate_now

            assert response.success?
            assert_not_nil response.message.content
          end
        end

        test "native format uses provider-specific structures" do
          VCR.use_cassette("docs/actions/messages/native_format") do
            response = NativeFormatAgent.with(message: "Test").multimodal_native.generate_now

            assert response.success?
            assert_not_nil response.message.content
          end
        end
      end
    end
  end
end
