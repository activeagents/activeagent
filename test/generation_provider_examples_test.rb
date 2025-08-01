require "test_helper"

class GenerationProviderExamplesTest < ActiveSupport::TestCase
  test "provider configuration examples" do
    # These are documentation examples only
    # region anthropic_provider_example
    class AnthropicConfigAgent < ActiveAgent::Base
      generate_with :anthropic,
        model: "claude-3-5-sonnet-20241022",
        temperature: 0.7
    end
    # endregion anthropic_provider_example
    
    # region google_provider_example
    class GoogleConfigAgent < ActiveAgent::Base
      generate_with :google,
        model: "gemini-pro",
        temperature: 0.5
    end
    # endregion google_provider_example
    
    # region custom_host_configuration
    class CustomHostAgent < ActiveAgent::Base
      generate_with :openai,
        host: "https://your-azure-openai-resource.openai.azure.com",
        api_key: "your-api-key",
        model: "gpt-4"
    end
    # endregion custom_host_configuration
    
    assert_equal :anthropic, AnthropicConfigAgent.generation_provider_name
    assert_equal :google, GoogleConfigAgent.generation_provider_name
    assert_equal :openai, CustomHostAgent.generation_provider_name
  end
  
  test "response object usage" do
    VCR.use_cassette("generation_response_usage_example") do
      # region generation_response_usage
      response = ApplicationAgent.with(message: "Hello").prompt_context.generate_now
      
      # Access response content
      content = response.message.content
      
      # Access response role
      role = response.message.role
      
      # Access full prompt context
      messages = response.prompt.messages
      
      # Access usage statistics (if available)
      usage = response.usage
      # endregion generation_response_usage
      
      doc_example_output(response)
      
      assert_not_nil content
      assert_equal :assistant, role
      assert messages.is_a?(Array)
    end
  end
end