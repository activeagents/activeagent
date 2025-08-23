require "test_helper"
require "active_agent/action_prompt/prompt"
require "active_agent/action_prompt/message"
require_relative "../../lib/active_agent/generation_provider/responses_adapter"

module ActiveAgent
  module GenerationProvider
    module OpenAIAdapters
      class ResponsesAdapterTest < ActiveSupport::TestCase
        def setup
          # Create a real prompt instance for testing
          @prompt = ActiveAgent::ActionPrompt::Prompt.new
        end

        test "handles simple text messages" do
          simple_messages = [
            ActiveAgent::ActionPrompt::Message.new(
              role: "system",
              content: "Talk like a pirate."
            ),
            ActiveAgent::ActionPrompt::Message.new(
              role: "user",
              content: "Are semicolons optional in JavaScript?"
            )
          ]

          @prompt.messages = simple_messages
          adapter = ResponsesAdapter.new(@prompt)

          result = adapter.input
          assert_equal 2, result.length  # The two messages we provided

          # Test first message (system)
          assert_equal "system", result[0][:role]
          assert_equal "Talk like a pirate.", result[0][:content]

          # Test second message (user)
          assert_equal "user", result[1][:role]
          assert_equal "Are semicolons optional in JavaScript?", result[1][:content]
        end

        test "handles multimodal content with text and image" do
          multimodal_message = ActiveAgent::ActionPrompt::Message.new(
            role: "user",
            content: [
              ActiveAgent::ActionPrompt::Message.new({content_type: "input_text", content: "what's in this image?"}),
              ActiveAgent::ActionPrompt::Message.new({content_type: "image_data", content: "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEAYABgAAD..."})
            ]
          )

          @prompt.messages = [multimodal_message]
          adapter = ResponsesAdapter.new(@prompt)

          result = adapter.input

          assert_equal 1, result.length # Just the multimodal message
          message = result[0]  # Get the single message

          assert_equal "user", message[:role]
          assert_instance_of Array, message[:content]
          assert_equal 2, message[:content].length

          # Test text content
          text_content = message[:content][0]
          assert_equal "input_text", text_content[:type]
          assert_equal "what's in this image?", text_content[:text]

          # Test image content
          image_content = message[:content][1]
          assert_equal "input_image", image_content[:type]
          assert_equal "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEAYABgAAD...", image_content[:image_url]
        end

        test "handles file content with text" do
          file_message = ActiveAgent::ActionPrompt::Message.new(
            role: "user",
            content: [
              ActiveAgent::ActionPrompt::Message.new({content_type: "file_data", metadata: {filename: "pdf_test_file.pdf"}, content: "data:application/pdf;base64,JVBERi0xLj..."}),
              ActiveAgent::ActionPrompt::Message.new({content_type: "input_text", content: "What is the first dragon in the book?"})
            ]
          )

          @prompt.messages = [file_message]
          adapter = ResponsesAdapter.new(@prompt)

          result = adapter.input

          assert_equal 1, result.length # Just the file message
          message = result[0]  # Get the single message

          assert_equal "user", message[:role]
          assert_instance_of Array, message[:content]
          assert_equal 2, message[:content].length

          # Test file content
          file_content = message[:content][0]
          assert_equal "input_file", file_content[:type]
          assert_equal "pdf_test_file.pdf", file_content[:filename]
          assert_equal "data:application/pdf;base64,JVBERi0xLj...", file_content[:file_data]

          # Test text content
          text_content = message[:content][1]
          assert_equal "input_text", text_content[:type]
          assert_equal "What is the first dragon in the book?", text_content[:text]
        end

        test "handles mixed simple and multimodal messages" do
          mixed_messages = [
            ActiveAgent::ActionPrompt::Message.new(
              role: "system",
              content: "Talk like a pirate."
            ),
            ActiveAgent::ActionPrompt::Message.new(
              role: "user",
              content: [
                ActiveAgent::ActionPrompt::Message.new({content_type: "input_text", content: "what's in this image?"}),
                ActiveAgent::ActionPrompt::Message.new({content_type: "image_data", content: "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEAYABgAAD..."})
              ]
            ),
            ActiveAgent::ActionPrompt::Message.new(
              role: "user",
              content: "Are semicolons optional in JavaScript?"
            )
          ]

          @prompt.messages = mixed_messages
          adapter = ResponsesAdapter.new(@prompt)

          result = adapter.input

          assert_equal 3, result.length # Just the 3 messages

          # Test simple text message (system)
          assert_equal "system", result[0][:role]
          assert_equal "Talk like a pirate.", result[0][:content]

          # Test multimodal message
          assert_equal "user", result[1][:role]
          assert_instance_of Array, result[1][:content]

          # Test another simple text message
          assert_equal "user", result[2][:role]
          assert_equal "Are semicolons optional in JavaScript?", result[2][:content]
        end

        test "handles string content for non-array messages" do
          string_message = ActiveAgent::ActionPrompt::Message.new(
            role: "user",
            content: "This is a simple string message"
          )

          @prompt.messages = [string_message]
          adapter = ResponsesAdapter.new(@prompt)

          result = adapter.input

          assert_equal 1, result.length # Just the string message
          message = result[0]  # Get the single message

          assert_equal "user", message[:role]
          assert_equal "This is a simple string message", message[:content]
        end

        test "raises error for unsupported content type" do
          unsupported_message = ActiveAgent::ActionPrompt::Message.new(
            role: "user",
            content: [
              ActiveAgent::ActionPrompt::Message.new({content_type: "unsupported_type", content: "some data"})
            ]
          )

          @prompt.messages = [unsupported_message]
          adapter = ResponsesAdapter.new(@prompt)

          assert_raises(ArgumentError, "Unsupported content type in message") do
            adapter.input
          end
        end

        test "handles empty messages array" do
          @prompt.messages = []
          adapter = ResponsesAdapter.new(@prompt)

          result = adapter.input

          assert_equal 0, result.length # No messages
        end

        test "handles complex multimodal scenarios from examples" do
          # Test the exact scenario from your examples
          complex_messages = [
            ActiveAgent::ActionPrompt::Message.new(
              role: "system",
              content: "Talk like a pirate."
            ),
            ActiveAgent::ActionPrompt::Message.new(
              role: "user",
              content: "Are semicolons optional in JavaScript?"
            ),
            ActiveAgent::ActionPrompt::Message.new(
              role: "user",
              content: [
                ActiveAgent::ActionPrompt::Message.new({content_type: "input_text", content: "what's in this image?"}),
                ActiveAgent::ActionPrompt::Message.new({content_type: "image_data", content: "data:image/jpeg;base64,base64_image_data_here"})
              ]
            ),
            ActiveAgent::ActionPrompt::Message.new(
              role: "user",
              content: [
                ActiveAgent::ActionPrompt::Message.new({content_type: "file_data", metadata: {filename: "pdf_test_file.pdf"}, content: "data:application/pdf;base64,base64_pdf_data_here"}),
                ActiveAgent::ActionPrompt::Message.new({content_type: "input_text", content: "What is the first dragon in the book?"})
              ]
            )
          ]

          @prompt.messages = complex_messages
          adapter = ResponsesAdapter.new(@prompt)

          result = adapter.input

          assert_equal 4, result.length # Just the 4 messages

          # Test developer message
          assert_equal "system", result[0][:role]
          assert_equal "Talk like a pirate.", result[0][:content]

          # Test simple user message
          assert_equal "user", result[1][:role]
          assert_equal "Are semicolons optional in JavaScript?", result[1][:content]

          # Test multimodal image message
          image_message = result[2]
          assert_equal "user", image_message[:role]
          assert_equal 2, image_message[:content].length
          assert_equal "input_text", image_message[:content][0][:type]
          assert_equal "what's in this image?", image_message[:content][0][:text]
          assert_equal "input_image", image_message[:content][1][:type]
          assert_equal "data:image/jpeg;base64,base64_image_data_here", image_message[:content][1][:image_url]

          # Test multimodal file message
          file_message = result[3]
          assert_equal "user", file_message[:role]
          assert_equal 2, file_message[:content].length
          assert_equal "input_file", file_message[:content][0][:type]
          assert_equal "pdf_test_file.pdf", file_message[:content][0][:filename]
          assert_equal "data:application/pdf;base64,base64_pdf_data_here", file_message[:content][0][:file_data]
          assert_equal "input_text", file_message[:content][1][:type]
          assert_equal "What is the first dragon in the book?", file_message[:content][1][:text]
        end

        test "initializes with prompt" do
          prompt = ActiveAgent::ActionPrompt::Prompt.new
          adapter = ResponsesAdapter.new(prompt)

          assert_equal prompt, adapter.prompt
        end
      end
    end
  end
end
