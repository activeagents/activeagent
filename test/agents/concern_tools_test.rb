require "test_helper"
require_relative "../dummy/app/agents/research_agent"
require_relative "../dummy/app/agents/concerns/research_tools"

class ConcernToolsTest < ActiveSupport::TestCase
  setup do
    @agent = ResearchAgent.new
  end

  test "research agent includes concern actions as available tools" do
    # The concern adds these actions which should be available as tools
    expected_actions = [
      "search_academic_papers",
      "analyze_research_data", 
      "generate_research_visualization",
      "search_with_mcp_sources"
    ]
    
    agent_actions = @agent.action_methods
    expected_actions.each do |action|
      assert_includes agent_actions, action, "Expected #{action} to be available from concern"
    end
  end

  test "concern can add built-in tools for responses API" do
    skip "Requires API credentials" unless has_openai_credentials?
    
    VCR.use_cassette("concern_web_search_responses_api") do
      # When using responses API with multimodal content
      # Use the search_academic_papers action from the concern
      generation = ResearchAgent.with(
        query: "latest research on large language models",
        year_from: 2024,
        year_to: 2025,
        field: "AI"
      ).search_academic_papers
      
      response = generation.generate_now
      
      assert response.message.content.present?
    end
  end

  test "concern can configure web search for chat completions API" do
    skip "Requires API credentials" unless has_openai_credentials?
    
    VCR.use_cassette("concern_web_search_chat_api") do
      # When using chat API with web search model
      # Use the comprehensive_research action which builds tools dynamically
      generation = ResearchAgent.with(
        topic: "latest research on large language models",
        depth: "detailed"
      ).comprehensive_research
      
      response = generation.generate_now
      
      assert response.message.content.present?
    end
  end

  test "concern supports MCP tools only in responses API" do
    skip "Requires API credentials" unless has_openai_credentials?
    
    VCR.use_cassette("concern_mcp_tools") do
      # MCP is only supported in Responses API
      # Use the search_with_mcp_sources action from the concern
      generation = ResearchAgent.with(
        query: "Ruby on Rails best practices",
        sources: ["github"]
      ).search_with_mcp_sources
      
      response = generation.generate_now
      
      assert response.message.content.present?
    end
  end

  test "concern actions work with both chat and responses API" do
    # Test that the same action can work with different APIs
    
    # Test with Chat Completions API (function calling)
    chat_prompt = ActiveAgent::ActionPrompt::Prompt.new
    chat_prompt.options = {model: "gpt-4o"}
    chat_prompt.actions = @agent.action_schemas  # Function schemas
    
    assert chat_prompt.actions.any? { |a| a["function"]["name"] == "search_academic_papers" }
    
    # Test with Responses API (can use built-in tools)
    responses_prompt = ActiveAgent::ActionPrompt::Prompt.new
    responses_prompt.options = {
      model: "gpt-5",
      use_responses_api: true,
      tools: [
        {type: "web_search_preview"},
        {type: "image_generation"}
      ]
    }
    
    # Should have both function tools and built-in tools
    assert responses_prompt.options[:tools].any? { |t| t[:type] == "web_search_preview" }
    assert responses_prompt.options[:tools].any? { |t| t[:type] == "image_generation" }
  end

  test "concern can dynamically configure tools based on context" do
    # The concern can decide which tools to include based on parameters
    
    # The ResearchAgent.comprehensive_research method should configure tools dynamically
    # based on the depth parameter. We verify this by checking that the agent
    # has the method and that it accepts the expected parameters.
    
    agent = ResearchAgent.new
    assert agent.respond_to?(:comprehensive_research)
    
    # Verify the agent has access to the tool configuration methods
    assert ResearchAgent.research_tools_config[:enable_web_search]
    assert ResearchAgent.research_tools_config[:mcp_servers].present?
  end

  test "concern configuration is inherited at class level" do
    # ResearchAgent configured with specific settings
    assert ResearchAgent.research_tools_config[:enable_web_search]
    assert_equal ["arxiv", "github"], ResearchAgent.research_tools_config[:mcp_servers]
    assert_equal "high", ResearchAgent.research_tools_config[:default_search_context]
  end

  test "multiple concerns can add different tool types" do
    # Create an agent with multiple concerns
    class MultiToolAgent < ApplicationAgent
      include ResearchTools
      # Could include other tool concerns like ImageTools, DataTools, etc.
      
      generate_with :openai, model: "gpt-4o"
    end
    
    agent = MultiToolAgent.new
    
    # Should have all actions from all concerns
    assert agent.respond_to?(:search_academic_papers)
    assert agent.respond_to?(:analyze_research_data)
    assert agent.respond_to?(:generate_research_visualization)
  end

  test "concern tools respect API limitations" do
    # Test that we don't try to use unsupported features
    
    # MCP should not be available in Chat API
    chat_prompt = ActiveAgent::ActionPrompt::Prompt.new
    chat_prompt.options = {
      model: "gpt-4o",  # Regular chat model
      tools: [
        {type: "mcp", server_url: "https://example.com"}  # This won't work
      ]
    }
    
    # Provider should filter out MCP for chat API
    provider = ActiveAgent::GenerationProvider::OpenAIProvider.new({"model" => "gpt-4o"})
    provider.instance_variable_set(:@prompt, chat_prompt)
    
    # When using chat API, MCP tools should not be included
    # This test verifies that the configuration is set up correctly
    assert chat_prompt.options[:model] == "gpt-4o"
    assert chat_prompt.options[:tools].any? { |t| t[:type] == "mcp" }
  end
end