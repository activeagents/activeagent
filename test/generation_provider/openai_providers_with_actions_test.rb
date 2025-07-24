require "test_helper"

class OpenAIProvidersWithActionsTest < ActiveSupport::TestCase
  def setup
    @weather_agent = WeatherAgent.new
  end

  test "weather agent has action schemas from jbuilder templates" do
    schemas = @weather_agent.action_schemas
    
    assert schemas.any?, "Weather agent should have action schemas"
    
    weather_schema = schemas.first
    assert_equal "function", weather_schema["type"]
    assert weather_schema["function"]["name"].present?
    assert_equal "Get the current weather for a location", weather_schema["function"]["description"]
    assert weather_schema["function"]["parameters"]["properties"]["location"].present?
  end

  test "openai provider selects correct adapter for weather agent with tools" do
    VCR.use_cassette("weather_agent_with_tools") do
      skip_if_no_api_key

      # Use the weather agent which has proper jbuilder schemas
      prompt = @weather_agent.prompt(message: "What's the weather like in Paris?")
      
      # The prompt should have action schemas from jbuilder
      assert prompt.actions.any?, "Prompt should have actions from agent"
      
      config = {
        "api_key" => Rails.application.credentials.dig(:openai, :api_key),
        "model" => "gpt-4o-mini"
      }
      provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(config)
      
      # Should select chat completions adapter since it's just tools without structured output
      selected_adapter = provider.send(:select_adapter, prompt)
      assert_instance_of ActiveAgent::GenerationProvider::OpenAIAdapters::ChatCompletionsAdapter, selected_adapter
      
      # Generate response
      response = provider.generate(prompt)
      
      assert_instance_of ActiveAgent::GenerationProvider::Response, response
      assert_instance_of ActiveAgent::ActionPrompt::Message, response.message
      assert(response.message.content.present? || response.message.requested_actions.any?)
    end
  end

  test "translation agent with structured output uses responses adapter" do
    skip "Responses API not fully implemented yet - needs structured output example"
    
    # This would test a scenario where we have structured output requirements
    # that would trigger the responses adapter
  end

  test "chat completions adapter formats tools correctly" do
    prompt = @weather_agent.prompt(message: "What's the weather?")
    
    config = { "model" => "gpt-4o-mini" }
    adapter = ActiveAgent::GenerationProvider::OpenAIAdapters::ChatCompletionsAdapter.new(nil, config)
    
    # Test the tool formatting without making API calls
    formatted_tools = adapter.send(:format_tools_for_chat_completions, prompt.actions)
    
    assert formatted_tools.any?, "Should have formatted tools"
    
    tool = formatted_tools.first
    assert_equal "function", tool["type"]
    assert tool["function"]["name"].present?
    assert_equal "Get the current weather for a location", tool["function"]["description"]
  end

  private

  def skip_if_no_api_key
    skip "OpenAI API key not configured" unless Rails.application.credentials.dig(:openai, :api_key)
  end
end
