# frozen_string_literal: true

require "test_helper"
require_relative "../../lib/active_agent/providers/open_ai/responses/request"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        class RequestTypingTest < ActiveSupport::TestCase
          test "handles string input" do
            request = Request.new(
              model: "gpt-4o",
              input: "Hello, world!"
            )

            assert_equal "Hello, world!", request.input
            assert request.valid?
          end

          test "handles array input with user message" do
            request = Request.new(
              model: "gpt-4o",
              input: [
                { role: "user", content: "What is the weather?" }
              ]
            )

            assert_instance_of Array, request.input
            assert_equal 1, request.input.length
            assert_instance_of Requests::Inputs::UserMessage, request.input[0]
            assert_equal "user", request.input[0].role
            assert_equal "What is the weather?", request.input[0].content
          end

          test "handles multimodal input with text and image" do
            request = Request.new(
              model: "gpt-4o",
              input: [
                {
                  role: "user",
                  content: [
                    { type: "input_text", text: "What's in this image?" },
                    { type: "input_image", image_url: "data:image/jpeg;base64,..." }
                  ]
                }
              ]
            )

            assert_instance_of Array, request.input
            message = request.input[0]
            assert_instance_of Requests::Inputs::UserMessage, message
            assert_instance_of Array, message.content

            text_part = message.content[0]
            assert_instance_of Requests::Inputs::ContentParts::InputText, text_part
            assert_equal "input_text", text_part.type
            assert_equal "What's in this image?", text_part.text

            image_part = message.content[1]
            assert_instance_of Requests::Inputs::ContentParts::InputImage, image_part
            assert_equal "input_image", image_part.type
            assert_equal "data:image/jpeg;base64,...", image_part.image_url
          end

          test "handles file input" do
            request = Request.new(
              model: "gpt-4o",
              input: [
                {
                  role: "user",
                  content: [
                    { type: "input_file", filename: "document.pdf", file_data: "base64data..." },
                    { type: "input_text", text: "Summarize this document" }
                  ]
                }
              ]
            )

            message = request.input[0]
            file_part = message.content[0]

            assert_instance_of Requests::Inputs::ContentParts::InputFile, file_part
            assert_equal "input_file", file_part.type
            assert_equal "document.pdf", file_part.filename
            assert_equal "base64data...", file_part.file_data
          end

          test "handles tool_choice string" do
            request = Request.new(
              model: "gpt-4o",
              tool_choice: "auto"
            )

            assert_instance_of Requests::ToolChoice, request.tool_choice
            assert_equal "auto", request.tool_choice.mode
          end

          test "handles tool_choice object" do
            request = Request.new(
              model: "gpt-4o",
              tool_choice: {
                type: "function",
                function: { name: "get_weather" }
              }
            )

            assert_instance_of Requests::ToolChoice, request.tool_choice
            assert_equal "function", request.tool_choice.type
            assert_equal({ name: "get_weather" }, request.tool_choice.function)
          end

          test "handles tools array with function tool" do
            request = Request.new(
              model: "gpt-4o",
              tools: [
                {
                  type: "function",
                  function: {
                    name: "get_weather",
                    description: "Get the current weather",
                    parameters: {
                      type: "object",
                      properties: {
                        location: { type: "string" }
                      }
                    }
                  }
                }
              ]
            )

            assert_instance_of Array, request.tools
            assert_equal 1, request.tools.length
            assert_instance_of Requests::Tools::FunctionTool, request.tools[0]
            assert_equal "function", request.tools[0].type
            assert_equal "get_weather", request.tools[0].function[:name]
          end

          test "handles built-in tools" do
            request = Request.new(
              model: "gpt-4o",
              tools: [
                { type: "web_search" },
                { type: "code_interpreter" },
                { type: "file_search" }
              ]
            )

            assert_instance_of Array, request.tools
            assert_equal 3, request.tools.length

            assert_instance_of Requests::Tools::WebSearchTool, request.tools[0]
            assert_instance_of Requests::Tools::CodeInterpreterTool, request.tools[1]
            assert_instance_of Requests::Tools::FileSearchTool, request.tools[2]
          end

          test "serializes to hash correctly" do
            request = Request.new(
              model: "gpt-4o",
              input: [
                {
                  role: "user",
                  content: [
                    { type: "input_text", text: "Hello" }
                  ]
                }
              ],
              tool_choice: "auto",
              tools: [
                { type: "web_search" }
              ],
              temperature: 0.7,
              max_output_tokens: 1000
            )

            hash = request.to_h

            assert_equal "gpt-4o", hash[:model]
            assert_instance_of Array, hash[:input]
            assert_equal "user", hash[:input][0][:role]
            assert_equal "input_text", hash[:input][0][:content][0][:type]
            assert_equal "Hello", hash[:input][0][:content][0][:text]
            assert_equal "auto", hash[:tool_choice]
            assert_equal "web_search", hash[:tools][0][:type]
            assert_equal 0.7, hash[:temperature]
            assert_equal 1000, hash[:max_output_tokens]
          end
        end
      end
    end
  end
end
