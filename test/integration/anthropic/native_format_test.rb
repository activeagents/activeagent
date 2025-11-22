# frozen_string_literal: true

require_relative "../test_helper"

module Integration
  module Anthropic
    class NativeFormatTest < ActiveSupport::TestCase
      include Integration::TestHelper

      class TestAgent < ActiveAgent::Base
        generate_with :anthropic, model: "claude-sonnet-4-5-20250929"

        ###############################################################
        # Basic Request
        ###############################################################
        BASIC_REQUEST = {
          model: "claude-sonnet-4-5-20250929",
          messages: [
            {
              role: "user",
              content: "Hello, Claude!"
            }
          ],
          max_tokens: 1024
        }
        def basic_request
          prompt(
            messages: [
              { role: "user", content: "Hello, Claude!" }
            ],
            max_tokens: 1024
          )
        end

        ###############################################################
        # Request with System Prompt
        ###############################################################
        SYSTEM_PROMPT = {
          model: "claude-sonnet-4-5-20250929",
          system: "You are a helpful assistant.",
          messages: [
            {
              role: "user",
              content: "What is 2+2?"
            }
          ],
          max_tokens: 1024,
          temperature: 0.7
        }
        def system_prompt
          prompt(
            system: "You are a helpful assistant.",
            messages: [
              { role: "user", content: "What is 2+2?" }
            ],
            max_tokens: 1024,
            temperature: 0.7
          )
        end

        ###############################################################
        # Request with Tools
        ###############################################################
        TOOLS_REQUEST = {
          model: "claude-sonnet-4-5-20250929",
          messages: [
            {
              role: "user",
              content: "What's the weather in San Francisco?"
            }
          ],
          max_tokens: 1024,
          tools: [
            {
              name: "get_weather",
              description: "Get the current weather in a given location",
              input_schema: {
                type: "object",
                properties: {
                  location: {
                    type: "string",
                    description: "The city and state, e.g. San Francisco, CA"
                  }
                },
                required: [ "location" ]
              }
            }
          ],
          tool_choice: { type: "auto" }
        }
        def tools_request
          prompt(
            messages: [
              { role: "user", content: "What's the weather in San Francisco?" }
            ],
            max_tokens: 1024,
            tools: [
              {
                name: "get_weather",
                description: "Get the current weather in a given location",
                input_schema: {
                  type: "object",
                  properties: {
                    location: {
                      type: "string",
                      description: "The city and state, e.g. San Francisco, CA"
                    }
                  },
                  required: [ "location" ]
                }
              }
            ],
            tool_choice: { type: "auto" }
          )
        end

        def get_weather(location:)
          { location:, temperature: "72°F", conditions: "sunny" }
        end

        ###############################################################
        # Request with Extended Thinking
        ###############################################################
        EXTENDED_THINKING = {
          model: "claude-sonnet-4-5-20250929",
          messages: [
            {
              role: "user",
              content: "Solve this complex math problem..."
            }
          ],
          max_tokens: 4096,
          thinking: {
            type: "enabled",
            budget_tokens: 2048
          }
        }
        def extended_thinking
          prompt(
            messages: [
              { role: "user", content: "Solve this complex math problem..." }
            ],
            max_tokens: 4096,
            thinking: {
              type: "enabled",
              budget_tokens: 2048
            }
          )
        end

        ###############################################################
        # Request with Metadata
        ###############################################################
        METADATA_REQUEST = {
          model: "claude-sonnet-4-5-20250929",
          messages: [
            {
              role: "user",
              content: "Hello!"
            }
          ],
          max_tokens: 1024,
          metadata: {
            user_id: "user-123"
          }
        }
        def metadata_request
          prompt(
            messages: [
              { role: "user", content: "Hello!" }
            ],
            max_tokens: 1024,
            metadata: {
              user_id: "user-123"
            }
          )
        end

        ###############################################################
        # Request with Multiple Messages
        ###############################################################
        MULTIPLE_MESSAGES = {
          model: "claude-sonnet-4-5-20250929",
          messages: [
            { role: "user", content: "Hello there." },
            { role: "assistant", content: "Hi, I'm Claude. How can I help you?" },
            { role: "user", content: "Can you explain LLMs in plain English?" }
          ],
          max_tokens: 1024
        }
        def multiple_messages
          prompt(
            messages: [
              { role: "user", content: "Hello there." },
              { role: "assistant", content: "Hi, I'm Claude. How can I help you?" },
              { role: "user", content: "Can you explain LLMs in plain English?" }
            ],
            max_tokens: 1024
          )
        end

        ###############################################################
        # User Message with Content Blocks
        ###############################################################
        USER_MESSAGE_CONTENT_BLOCKS = {
          model: "claude-sonnet-4-5-20250929",
          messages: [
            {
              role: "user",
              content: [
                { type: "text", text: "What's in this image?" },
                {
                  type: "image",
                  source: {
                    type: "base64",
                    media_type: "image/jpeg",
                    data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
                  }
                }
              ]
            }
          ],
          max_tokens: 1024
        }
        def user_message_content_blocks
          prompt(
            messages: [
              {
                role: "user",
                content: [
                  { type: "text", text: "What's in this image?" },
                  {
                    type: "image",
                    source: {
                      type: "base64",
                      media_type: "image/jpeg",
                      data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
                    }
                  }
                ]
              }
            ],
            max_tokens: 1024
          )
        end

        ###############################################################
        # Assistant Message with Tool Use
        ###############################################################
        ASSISTANT_MESSAGE_TOOL_USE = {
          model: "claude-sonnet-4-5-20250929",
          messages: [
            {
              role: "user",
              content: "What's the weather in San Francisco?"
            },
            {
              role: "assistant",
              content: [
                { type: "text", text: "I'll check the weather for you." },
                {
                  type: "tool_use",
                  id: "toolu_123",
                  name: "get_weather",
                  input: { location: "San Francisco, CA" }
                }
              ]
            },
            {
              role: "user",
              content: [
                {
                  type: "tool_result",
                  tool_use_id: "toolu_123",
                  content: "72°F and sunny"
                }
              ]
            }
          ],
          max_tokens: 1024
        }
        def assistant_message_tool_use
          prompt(
            messages: [
              { role: "user", content: "What's the weather in San Francisco?" },
              {
                role: "assistant",
                content: [
                  { type: "text", text: "I'll check the weather for you." },
                  {
                    type: "tool_use",
                    id: "toolu_123",
                    name: "get_weather",
                    input: { location: "San Francisco, CA" }
                  }
                ]
              },
              {
                role: "user",
                content: [
                  {
                    type: "tool_result",
                    tool_use_id: "toolu_123",
                    content: "72°F and sunny"
                  }
                ]
              }
            ],
            max_tokens: 1024
          )
        end

        ###############################################################
        # Tool Choice: Auto (Default)
        ###############################################################
        TOOL_CHOICE_AUTO = {
          model: "claude-sonnet-4-5-20250929",
          messages: [
            { role: "user", content: "What's the weather?" }
          ],
          max_tokens: 1024,
          tools: [
            {
              name: "get_weather",
              description: "Get weather",
              input_schema: {
                type: "object",
                properties: {
                  location: { type: "string" }
                },
                required: [ "location" ]
              }
            }
          ],
          tool_choice: { type: "auto" }
        }
        def tool_choice_auto
          prompt(
            messages: [
              { role: "user", content: "What's the weather?" }
            ],
            max_tokens: 1024,
            tools: [
              {
                name: "get_weather",
                description: "Get weather",
                input_schema: {
                  type: "object",
                  properties: {
                    location: { type: "string" }
                  },
                  required: [ "location" ]
                }
              }
            ],
            tool_choice: { type: "auto" }
          )
        end

        ###############################################################
        # Tool Choice: Any (Force Tool Use)
        ###############################################################
        TOOL_CHOICE_ANY = {
          model: "claude-sonnet-4-5-20250929",
          messages: [
            { role: "user", content: "What's the weather?" }
          ],
          max_tokens: 1024,
          tools: [
            {
              name: "get_weather",
              description: "Get weather",
              input_schema: {
                type: "object",
                properties: {
                  location: { type: "string" }
                },
                required: [ "location" ]
              }
            }
          ],
          tool_choice: { type: "any" }
        }
        def tool_choice_any
          prompt(
            messages: [
              { role: "user", content: "What's the weather?" }
            ],
            max_tokens: 1024,
            tools: [
              {
                name: "get_weather",
                description: "Get weather",
                input_schema: {
                  type: "object",
                  properties: {
                    location: { type: "string" }
                  },
                  required: [ "location" ]
                }
              }
            ],
            tool_choice: { type: "any" }
          )
        end

        ###############################################################
        # Tool Choice: Specific Tool
        ###############################################################
        TOOL_CHOICE_SPECIFIC = {
          model: "claude-sonnet-4-5-20250929",
          messages: [
            { role: "user", content: "What's the weather?" }
          ],
          max_tokens: 1024,
          tools: [
            {
              name: "get_weather",
              description: "Get weather",
              input_schema: {
                type: "object",
                properties: {
                  location: { type: "string" }
                },
                required: [ "location" ]
              }
            }
          ],
          tool_choice: { type: "tool", name: "get_weather" }
        }
        def tool_choice_specific
          prompt(
            messages: [
              { role: "user", content: "What's the weather?" }
            ],
            max_tokens: 1024,
            tools: [
              {
                name: "get_weather",
                description: "Get weather",
                input_schema: {
                  type: "object",
                  properties: {
                    location: { type: "string" }
                  },
                  required: [ "location" ]
                }
              }
            ],
            tool_choice: { type: "tool", name: "get_weather" }
          )
        end

        ###############################################################
        # Tool Choice: Disable Parallel Tool Use
        ###############################################################
        TOOL_CHOICE_DISABLE_PARALLEL = {
          model: "claude-sonnet-4-5-20250929",
          messages: [
            { role: "user", content: "What's the weather?" }
          ],
          max_tokens: 1024,
          tools: [
            {
              name: "get_weather",
              description: "Get weather",
              input_schema: {
                type: "object",
                properties: {
                  location: { type: "string" }
                },
                required: [ "location" ]
              }
            }
          ],
          tool_choice: {
            type: "auto",
            disable_parallel_tool_use: true
          }
        }
        def tool_choice_disable_parallel
          prompt(
            messages: [
              { role: "user", content: "What's the weather?" }
            ],
            max_tokens: 1024,
            tools: [
              {
                name: "get_weather",
                description: "Get weather",
                input_schema: {
                  type: "object",
                  properties: {
                    location: { type: "string" }
                  },
                  required: [ "location" ]
                }
              }
            ],
            tool_choice: {
              type: "auto",
              disable_parallel_tool_use: true
            }
          )
        end

        ###############################################################
        # Thinking Configuration: Disabled
        ###############################################################
        THINKING_DISABLED = {
          model: "claude-sonnet-4-5-20250929",
          messages: [
            { role: "user", content: "Hello!" }
          ],
          max_tokens: 1024,
          thinking: { type: "disabled" }
        }
        def thinking_disabled
          prompt(
            messages: [
              { role: "user", content: "Hello!" }
            ],
            max_tokens: 1024,
            thinking: { type: "disabled" }
          )
        end

        ###############################################################
        # Request with Streaming
        ###############################################################
        STREAMING = {
          model: "claude-sonnet-4-5-20250929",
          messages: [
            { role: "user", content: "Tell me a story." }
          ],
          max_tokens: 1024,
          stream: true
        }
        def streaming
          prompt(
            messages: [
              { role: "user", content: "Tell me a story." }
            ],
            max_tokens: 1024,
            stream: true
          )
        end

        ###############################################################
        # Request with Streaming and Tools
        ###############################################################
        TOOLS_WITH_STREAMING = TOOLS_REQUEST.merge(stream: true)
        def tools_with_streaming
          prompt(
            messages: [
              { role: "user", content: "What's the weather in San Francisco?" }
            ],
            max_tokens: 1024,
            tools: [
              {
                name: "get_weather",
                description: "Get the current weather in a given location",
                input_schema: {
                  type: "object",
                  properties: {
                    location: {
                      type: "string",
                      description: "The city and state, e.g. San Francisco, CA"
                    }
                  },
                  required: [ "location" ]
                }
              }
            ],
            tool_choice: { type: "auto" },
            stream: true
          )
        end

        ###############################################################
        # Request with Temperature and Sampling Parameters
        ###############################################################
        SAMPLING_PARAMETERS = {
          model: "claude-sonnet-4-5-20250929",
          messages: [
            { role: "user", content: "Write a creative story." }
          ],
          max_tokens: 2048,
          top_k: 50,
          top_p: 0.95
        }
        def sampling_parameters
          prompt(
            messages: [
              { role: "user", content: "Write a creative story." }
            ],
            max_tokens: 2048,
            top_k: 50,
            top_p: 0.95
          )
        end

        ###############################################################
        # Request with Stop Sequences
        ###############################################################
        STOP_SEQUENCES = {
          model: "claude-sonnet-4-5-20250929",
          messages: [
            { role: "user", content: "Generate a JSON object representing a person with a name, email, and phone number ." }
          ],
          max_tokens: 1024,
          stop_sequences: [ "}" ]
        }
        def stop_sequences
          prompt(
            messages: [
              { role: "user", content: "Generate a JSON object representing a person with a name, email, and phone number ." }
            ],
            max_tokens: 1024,
            stop_sequences: [ "}" ]
          )
        end

        ###############################################################
        # Native Format MCP Server
        ###############################################################
        MCP_SERVER = {
          model: "claude-sonnet-4-5-20250929",
          messages: [
            {
              role: "user",
              content: "What tools do you have available?"
            }
          ],
          max_tokens: 1024,
          mcp_servers: [
            {
              type: "url",
              url: "https://demo-day.mcp.cloudflare.com/sse",
              name: "cloudflare-demo"
            }
          ]
        }
        def mcp_server
          prompt(
            messages: [
              { role: "user", content: "What tools do you have available?" }
            ],
            max_tokens: 1024,
            mcp_servers: [
              {
                type: "url",
                url: "https://demo-day.mcp.cloudflare.com/sse",
                name: "cloudflare-demo"
              }
            ]
          )
        end
      end

      ################################################################################
      # This automatically runs all the tests for these the test actions
      ################################################################################
      [
        :basic_request,
        :system_prompt,
        :tools_request,
        :extended_thinking,
        :metadata_request,
        :multiple_messages,
        :user_message_content_blocks,
        :assistant_message_tool_use,
        :tool_choice_auto,
        :tool_choice_any,
        :tool_choice_specific,
        :tool_choice_disable_parallel,
        :thinking_disabled,
        :streaming,
        :tools_with_streaming,
        :sampling_parameters,
        :stop_sequences,
        :mcp_server
      ].each do |action_name|
        test_request_builder(TestAgent, action_name, :generate_now, TestAgent.const_get(action_name.to_s.upcase, true))
      end
    end
  end
end
