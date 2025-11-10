require "test_helper"

module Framework
  class ProvidersExamplesTest < ActiveAgentTestCase
    test "provider configuration examples" do
      # Mock configurations for providers that might not be configured
      mock_config = {
        "anthropic" => {
          "service" => "Anthropic",
          "api_key" => "test-key",
          "model" => "claude-3-5-sonnet-20241022"
        },
        "openai" => {
          "service" => "OpenAI",
          "api_key" => "test-key",
          "model" => "gpt-4"
        },
        "open_router" => {
          "service" => "OpenRouter",
          "api_key" => "test-key",
          "model" => "anthropic/claude-3-5-sonnet"
        }
      }

      with_active_agent_config(mock_config) do
        # These are documentation examples only
        # region anthropic_provider_example
        class AnthropicConfigAgent < ActiveAgent::Base
          generate_with :anthropic,
            model: "claude-3-5-sonnet-20241022",
            temperature: 0.7
        end
        # endregion anthropic_provider_example

        # region open_router_provider_example
        class OpenRouterConfigAgent < ActiveAgent::Base
          generate_with :open_router,
            model: "anthropic/claude-3-5-sonnet",
            temperature: 0.5
        end
        # endregion open_router_provider_example

        # region custom_host_configuration
        class CustomHostAgent < ActiveAgent::Base
          generate_with :openai,
            host: "https://your-azure-openai-resource.openai.azure.com",
            api_key: "your-api-key",
            model: "gpt-4"
        end
        # endregion custom_host_configuration

        assert_equal ActiveAgent::Providers::AnthropicProvider, AnthropicConfigAgent.prompt_provider_klass
        assert_equal ActiveAgent::Providers::OpenRouterProvider, OpenRouterConfigAgent.prompt_provider_klass
        assert_equal ActiveAgent::Providers::OpenAIProvider, CustomHostAgent.prompt_provider_klass
      end
    end

    test "response object usage" do
      VCR.use_cassette("docs/framework/providers_examples/generation_response_usage_example") do
        # region generation_response_usage
        response = ApplicationAgent.prompt(message: "Hello").generate_now

        # Access response content
        content = response.message.content

        # Access response role
        role = response.message.role

        # Access all messages from conversation
        messages = response.messages

        # Access request context
        context = response.context

        # Access usage statistics (if available)
        usage = response.usage
        prompt_tokens = response.prompt_tokens
        completion_tokens = response.completion_tokens
        # endregion generation_response_usage

        doc_example_output(response)

        assert_not_nil content
        assert_equal "assistant", role
        assert messages.is_a?(Array)
        assert context.is_a?(Hash)
        assert usage.is_a?(Hash) if usage
        assert prompt_tokens.is_a?(Integer) if prompt_tokens
        assert completion_tokens.is_a?(Integer) if completion_tokens
      end
    end
  end
end
