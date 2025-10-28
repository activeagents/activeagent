# frozen_string_literal: true

require_relative "../../../test_helper"

module Integration
  module OpenAI
    module Responses
      module CommonFormat
        class MessagesTest < ActiveSupport::TestCase
          include Integration::TestHelper

          DATA_TYPES   = %i[image document]
          DATA_FORMATS = %i[url base64] # attachment
          IMAGE_HTTP   = "https://framerusercontent.com/images/oEx786EYW2ZVL4Xf9hparOVLjHI.png?scale-down-to=64"
          IMAGE_BASE64 = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
          FILE_HTTP    = "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf"
          FILE_BASE64  = begin
            file_path = Rails.root.join("../fixtures/files/sample_resume.pdf")
            base64_data = Base64.strict_encode64(File.read(file_path))
            "data:application/pdf;base64,#{base64_data}"
          end

          SOURCE_DATA = {
            image:    { url: IMAGE_HTTP, base64: IMAGE_BASE64 },
            document: { url: FILE_HTTP,  base64: FILE_BASE64 }
          }
          SOURCE_PAYLOAD = {
            image: {
              url: {
                type: "input_image",
                image_url: IMAGE_HTTP
              },
              base64: {
                type: "input_image",
                image_url: IMAGE_BASE64
              }
            },
            document: {
              url: {
                type: "input_file",
                file_url: FILE_HTTP
              },
              base64: {
                type: "input_file",
                filename: "document.pdf",
                file_data: FILE_BASE64
              }
            }
          }

          class TestAgent < ActiveAgent::Base
            generate_with :openai, model: "gpt-4.1"

            # def templates_default
            #   prompt
            # end

            # def templates_symbol
            #   prompt :default
            # end

            # def templates_proc
            #   prompt ->{ "Result" }
            # end

            TEXT_BARE = {
              model: "gpt-4.1",
              input: "What is the capital of France?"
            }
            def text_bare
              prompt("What is the capital of France?")
            end

            TEXT_MESSAGE_BARE = {
              model: "gpt-4.1",
              input: "Explain quantum computing in bare terms."
            }
            def text_message_bare
              prompt(input: "Explain quantum computing in bare terms.")
            end

            TEXT_MESSAGE_OBJECT = {
              model: "gpt-4.1",
              input: "What are the main differences between Ruby and Python?"
            }
            def text_message_object
              prompt(message: { text: "What are the main differences between Ruby and Python?" })
            end

            TEXTS_BARE = {
              model: "gpt-4.1",
              input: [
                {
                  role: "user",
                  content: [
                    {
                      type: "input_text",
                      text: "Tell me a fun fact about Ruby programming."
                    },
                    {
                      type: "input_text",
                      text: "Now explain why that's interesting."
                    }
                  ]
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
              model: "gpt-4.1",
              input: [
                {
                  role: "user",
                  content: [
                    {
                      type: "input_text",
                      text: "Tell me a fun fact about Ruby programming."
                    },
                    {
                      type: "input_text",
                      text: "Now explain why that's interesting."
                    }
                  ]
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
              model: "gpt-4.1",
              input: [
                {
                  role: "assistant",
                  content:  "I can help you with programming questions."
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

            DATA_TYPES.each do |data_type|
              DATA_FORMATS.each do |data_format|
                attr_name  = data_type
                attr_value = SOURCE_DATA.fetch(data_type).fetch(data_format)
                source     = SOURCE_PAYLOAD.fetch(data_type).fetch(data_format)

                const_set("#{data_type}_#{data_format}".upcase, {
                  model: "gpt-4.1",
                  input: [ {
                    role: "user",
                    content: [
                      {
                        type: "input_text",
                        text: "What's in this #{data_type}?"
                      },
                      source
                    ]
                  } ]
                })

                define_method("#{data_type}_#{data_format}_bare") do
                  prompt(
                    input: [
                      "What's in this #{data_type}?",
                      { attr_name => attr_value }
                    ]
                  )
                end

                define_method("#{data_type}_#{data_format}_message") do
                  prompt(
                    input: [
                      "What's in this #{data_type}?",
                      { attr_name => attr_value }
                    ]
                  )
                end

                define_method("#{data_type}_#{data_format}_messages") do
                  prompt(
                    input: [
                      "What's in this #{data_type}?",
                      { attr_name => attr_value }
                    ]
                  )
                end
              end
            end
          end

          ################################################################################
          # This automatically runs all the tests for these the test actions
          ################################################################################
          [
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

          [
            # Image tests
            :image_url_bare,
            :image_url_message,
            :image_url_messages,
            :image_base64_bare,
            :image_base64_message,
            :image_base64_messages,
            # :image_attachment_bare,
            # :image_attachment_message,
            # :image_attachment_messages,

            # File tests
            :document_url_bare,
            :document_url_message,
            :document_url_messages,
            :document_base64_bare,
            :document_base64_message,
            :document_base64_messages
            # :document_attachment_bare,
            # :document_attachment_message,
            # :document_attachment_messages
          ].each do |action_name|
            test_request_builder(
              TestAgent,
              action_name,
              :generate_now,
              TestAgent.const_get(action_name.to_s.split("_")[0..1].join("_").upcase))
          end
        end
      end
    end
  end
end
