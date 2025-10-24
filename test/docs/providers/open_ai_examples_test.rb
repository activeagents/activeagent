# frozen_string_literal: true

require "test_helper"

module Providers
  module OpenAIExamples
    class BasicConfiguration < ActiveSupport::TestCase
      test "basic agent configuration" do
        # region basic_configuration
        class OpenAIAgent < ApplicationAgent
          generate_with :openai, model: "gpt-4o-mini"

          def ask
            prompt(message: params[:message])
          end
        end
        # endregion basic_configuration

        agent = OpenAIAgent.new
        assert_respond_to agent, :ask
      end

      test "basic usage" do
        VCR.use_cassette("providers/openai/basic_usage") do
          # region basic_usage
          response = Providers::OpenAIAgent.with(
            message: "What is the Model Context Protocol?"
          ).ask.generate_now
          # endregion basic_usage

          assert response.success?
          assert_not_nil response.message.content
        end
      end
    end

    class APIVersions < ActiveSupport::TestCase
      test "responses API configuration" do
        # region responses_api_agent
        class ResponsesAgent < ApplicationAgent
          generate_with :openai,
            model: "gpt-4.1",
            api_version: :responses

          def chat
            prompt(message: params[:message])
          end
        end
        # endregion responses_api_agent

        agent = ResponsesAgent.new
        assert_respond_to agent, :chat
      end

      test "chat API configuration" do
        # region chat_api_agent
        class ChatAgent < ApplicationAgent
          generate_with :openai,
            model: "gpt-4o-mini",
            api_version: :chat

          def chat
            prompt(message: params[:message])
          end
        end
        # endregion chat_api_agent

        agent = ChatAgent.new
        assert_respond_to agent, :chat
      end
    end

    class WebSearch < ActiveSupport::TestCase
      test "web search with responses API" do
        # region web_search_agent
        class WebSearchAgent < ApplicationAgent
          generate_with :openai, model: "gpt-4o"

          def search_with_tools
            @query = params[:query]
            @context_size = params[:context_size] || "medium"

            prompt(
              message: @query,
              options: {
                use_responses_api: true,
                tools: [
                  {
                    type: "web_search_preview",
                    search_context_size: @context_size
                  }
                ]
              }
            )
          end
        end
        # endregion web_search_agent

        agent = WebSearchAgent.new
        assert_respond_to agent, :search_with_tools
      end
    end

    class ImageGeneration < ActiveSupport::TestCase
      test "image generation configuration" do
        # region image_generation_agent
        class MultimodalAgent < ApplicationAgent
          generate_with :openai, model: "gpt-4o", temperature: nil

          def create_image
            @description = params[:description]
            @size = params[:size] || "1024x1024"
            @quality = params[:quality] || "high"

            prompt(
              message: "Generate an image: #{@description}",
              options: {
                use_responses_api: true,
                tools: [
                  {
                    type: "image_generation",
                    size: @size,
                    quality: @quality,
                    format: "png"
                  }
                ]
              }
            )
          end
        end
        # endregion image_generation_agent

        agent = MultimodalAgent.new
        assert_respond_to agent, :create_image
      end
    end

    class MCPIntegration < ActiveSupport::TestCase
      test "MCP with built-in connectors" do
        # region mcp_builtin_connectors
        class McpIntegrationAgent < ApplicationAgent
          generate_with :openai, model: "gpt-5"

          def search_cloud_storage
            @query = params[:query]
            @service = params[:service] || "dropbox"
            @auth_token = params[:auth_token]

            prompt(
              message: "Search for: #{@query}",
              options: {
                use_responses_api: true,
                tools: [ build_connector_tool(@service, @auth_token) ]
              }
            )
          end

          private

          def build_connector_tool(service, auth_token)
            {
              type: "mcp",
              server_label: "connector_#{service}",
              authorization: { type: "bearer", token: auth_token }
            }
          end
        end
        # endregion mcp_builtin_connectors

        agent = McpIntegrationAgent.new
        assert_respond_to agent, :search_cloud_storage
      end

      test "MCP with custom servers" do
        # region mcp_custom_servers
        class CustomMcpAgent < ApplicationAgent
          generate_with :openai, model: "gpt-5"

          def use_custom_mcp
            @query = params[:query]
            @server_url = params[:server_url]
            @allowed_tools = params[:allowed_tools]

            prompt(
              message: @query,
              options: {
                use_responses_api: true,
                tools: [
                  {
                    type: "mcp",
                    server_label: "Custom MCP Server",
                    server_url: @server_url,
                    server_description: "Custom MCP server for specialized tasks",
                    require_approval: "always",
                    allowed_tools: @allowed_tools
                  }
                ]
              }
            )
          end
        end
        # endregion mcp_custom_servers

        agent = CustomMcpAgent.new
        assert_respond_to agent, :use_custom_mcp
      end

      test "tool configuration example" do
        # region tool_configuration_example
        tools_config = [
          {
            type: "web_search_preview",
            search_context_size: "high",
            user_location: {
              country: "US",
              city: "San Francisco"
            }
          },
          {
            type: "image_generation",
            size: "1024x1024",
            quality: "high",
            format: "png"
          },
          {
            type: "mcp",
            server_label: "GitHub",
            server_url: "https://api.githubcopilot.com/mcp/",
            require_approval: "never"
          }
        ]

        example_options = {
          use_responses_api: true,
          model: "gpt-5",
          tools: tools_config
        }
        # endregion tool_configuration_example

        assert_equal 3, tools_config.length
        assert example_options[:use_responses_api]
      end
    end

    class VisionCapabilities < ActiveSupport::TestCase
      test "vision agent configuration" do
        # region vision_agent
        class VisionAgent < ApplicationAgent
          generate_with :openai,
            model: "gpt-4o",
            api_version: :chat

          def analyze_image
            prompt(message: params[:message])
          end
        end
        # endregion vision_agent

        agent = VisionAgent.new
        assert_respond_to agent, :analyze_image
      end

      test "vision usage example" do
        skip "Vision/image support requires complex message content structure - see integration tests"
      end
    end

    class StructuredOutput < ActiveSupport::TestCase
      # region structured_output_agent
      class DataExtractionAgent < ApplicationAgent
        generate_with :openai,
          model: "gpt-4o-mini",
          response_format: { type: "json_object" }

        def extract_colors
          prompt("Return a JSON object with three primary colors in an array named 'colors'.")
        end
      end
      # endregion structured_output_agent

      test "structured output agent" do
        agent = DataExtractionAgent.new
        assert_respond_to agent, :extract_colors
      end

      test "structured output usage" do
        VCR.use_cassette("providers/openai/structured_output") do
          # region structured_output_usage
          response = DataExtractionAgent.extract_colors.generate_now
          colors = response.message.json_object
          # endregion structured_output_usage

          assert_kind_of Hash, colors
          assert colors.key?(:colors)
        end
      end
    end

    class Embeddings < ActiveSupport::TestCase
      test "embedding configuration" do
        # region embedding_configuration
        class EmbeddingAgent < ApplicationAgent
          embed_with :openai, model: "text-embedding-3-small"
        end
        # endregion embedding_configuration

        agent = EmbeddingAgent.new
        assert_not_nil agent
      end

      test "embedding usage" do
        VCR.use_cassette("providers/openai/embeddings_usage") do
          # region embedding_usage
          class EmbeddingAgent < ApplicationAgent
            embed_with :openai, model: "text-embedding-3-small"
          end

          response = EmbeddingAgent.embed("Your text to embed").embed_now
          embedding_vector = response.data.first[:embedding]  # Array of floats
          # endregion embedding_usage

          assert_kind_of Array, embedding_vector
          assert embedding_vector.all? { |v| v.is_a?(Float) }
        end
      end

      test "dimension reduction configuration" do
        # region dimension_reduction
        class DimensionReducedAgent < ApplicationAgent
          embed_with :openai,
            model: "text-embedding-3-small",
            dimensions: 512  # Reduce from default 1536
        end
        # endregion dimension_reduction

        agent = DimensionReducedAgent.new
        assert_not_nil agent
      end
    end

    class AzureOpenAI < ActiveSupport::TestCase
      test "azure configuration" do
        # region azure_configuration
        class AzureAgent < ApplicationAgent
          generate_with :openai,
            access_token: Rails.application.credentials.dig(:azure, :api_key),
            host: "https://your-resource.openai.azure.com",
            api_version: "2024-02-01",
            model: "your-deployment-name"
        end
        # endregion azure_configuration

        agent = AzureAgent.new
        assert_not_nil agent
      end
    end

    class ErrorHandling < ActiveSupport::TestCase
      test "error handling configuration" do
        # region error_handling
        class RobustAgent < ApplicationAgent
          generate_with :openai,
            model: "gpt-4o-mini",
            max_retries: 3,
            request_timeout: 30

          # Note: OpenAI::RateLimitError is only available when the OpenAI gem is loaded
          # This is a demonstration of how to handle errors
        end
        # endregion error_handling

        agent = RobustAgent.new
        assert_not_nil agent
      end
    end
  end
end
