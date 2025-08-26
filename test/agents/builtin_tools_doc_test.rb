require "test_helper"
require_relative "../dummy/app/agents/web_search_agent"
require_relative "../dummy/app/agents/multimodal_agent"

class BuiltinToolsDocTest < ActiveSupport::TestCase
  # region web_search_example
  test "web search with responses API example" do
    skip "Requires API credentials" unless has_openai_credentials?
    
    VCR.use_cassette("doc_web_search_responses") do
      generation = WebSearchAgent.with(
        query: "Latest Ruby on Rails 8 features",
        context_size: "high"
      ).search_with_tools
      
      result = generation.generate_now
      
      # The response includes web search results
      assert result.message.content.present?
      assert result.message.content.include?("Rails")
      
      doc_example_output(result)
    end
  end
  # endregion web_search_example
  
  # region image_generation_example
  test "image generation with responses API example" do
    skip "Requires API credentials" unless has_openai_credentials?
    
    VCR.use_cassette("doc_image_generation") do
      generation = MultimodalAgent.with(
        description: "A serene landscape with mountains and a lake at sunset",
        size: "1024x1024",
        quality: "high"
      ).create_image
      
      result = generation.generate_now
      
      # The response includes the generated image
      assert result.message.content.present?
      
      doc_example_output(result)
    end
  end
  # endregion image_generation_example
  
  # region combined_tools_example
  test "combining multiple built-in tools example" do
    skip "Requires API credentials" unless has_openai_credentials?
    
    VCR.use_cassette("doc_combined_tools") do
      generation = MultimodalAgent.with(
        topic: "Climate Change Impact",
        style: "modern"
      ).create_infographic
      
      result = generation.generate_now
      
      # The response uses both web search and image generation
      assert result.message.content.present?
      
      doc_example_output(result)
    end
  end
  # endregion combined_tools_example
  
  # region tool_configuration_example
  test "tool configuration in prompt options" do
    # Example showing how to configure built-in tools
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

    # Show how the options would be passed to prompt
    example_options = {
      use_responses_api: true,
      model: "gpt-5",
      tools: tools_config
    }

    # Verify the configuration structure
    assert example_options[:tools].is_a?(Array)
    assert_equal 3, example_options[:tools].length
    assert_equal "web_search_preview", example_options[:tools][0][:type]
    assert_equal "image_generation", example_options[:tools][1][:type]
    assert_equal "mcp", example_options[:tools][2][:type]

    doc_example_output({
      description: "Example configuration for built-in tools in prompt options",
      options: example_options,
      tools_configured: tools_config
    })
  end
  # endregion tool_configuration_example
end
