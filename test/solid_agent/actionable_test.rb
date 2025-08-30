require "test_helper"
require "solid_agent"

class SolidAgent::ActionableTest < ActiveSupport::TestCase
  # Test concern with actions
  module WebSearchActions
    extend ActiveSupport::Concern
    
    def search_web(query:, limit: 10)
      { results: ["result1", "result2"], count: 2 }
    end
    
    def browse_url(url:)
      { content: "Page content", status: 200 }
    end
    
    class_methods do
      def action_metadata
        {
          search_web: { description: "Search the web" },
          browse_url: { description: "Browse a URL" }
        }
      end
    end
  end
  
  # Test agent with various action types
  class MultiActionAgent < ActiveAgent::Base
    include SolidAgent::Actionable
    
    # Public method action
    def calculate(expression:)
      eval(expression)
    end
    
    # Include concern with actions
    include_actions WebSearchActions
    
    # Explicit action definition
    action :analyze_sentiment do
      description "Analyzes text sentiment"
      parameter :text, type: :string, required: true
      parameter :language, type: :string, default: "en"
      
      execute do |params|
        # Mock sentiment analysis
        { sentiment: "positive", confidence: 0.95 }
      end
    end
    
    # MCP server (mocked)
    mcp_server "filesystem", url: "npx @modelcontextprotocol/server-filesystem"
    
    # External tool (mocked)
    tool "browser" do
      provider BrowserAutomation
      actions [:navigate, :click, :screenshot]
    end
  end
  
  # Mock browser automation provider
  class BrowserAutomation
    def self.execute(action, params)
      { action: action, params: params, result: "success" }
    end
  end
  
  setup do
    @agent = MultiActionAgent.new
  end
  
  test "public methods become actions" do
    actions = MultiActionAgent.all_actions
    
    assert actions.key?(:calculate)
    assert_instance_of SolidAgent::Actionable::ActionDefinition, actions[:calculate]
  end
  
  test "includes actions from concerns" do
    result = @agent.search_web(query: "ruby gems")
    
    assert_equal({ results: ["result1", "result2"], count: 2 }, result)
    assert MultiActionAgent.registered_actions.key?(:search_web)
  end
  
  test "defines explicit actions with DSL" do
    assert MultiActionAgent.registered_actions.key?(:analyze_sentiment)
    
    action = MultiActionAgent.registered_actions[:analyze_sentiment]
    assert_equal "Analyzes text sentiment", action.description
    assert action.parameters.key?(:text)
    assert action.parameters[:text][:required]
    assert_equal "en", action.parameters[:language][:default]
  end
  
  test "executes defined actions" do
    result = @agent.analyze_sentiment(text: "I love this!")
    
    assert_equal({ sentiment: "positive", confidence: 0.95 }, result)
  end
  
  test "validates required parameters" do
    assert_raises ArgumentError do
      @agent.analyze_sentiment(language: "es") # Missing required 'text'
    end
  end
  
  test "validates parameter types" do
    # Mock validation
    action_def = MultiActionAgent.registered_actions[:analyze_sentiment]
    
    assert_raises ArgumentError do
      @agent.send(:validate_action_params, action_def, { text: 123 }) # Should be string
    end
  end
  
  test "registers MCP servers" do
    assert MultiActionAgent.mcp_servers.key?("filesystem")
    assert_equal "npx @modelcontextprotocol/server-filesystem", 
                 MultiActionAgent.mcp_servers["filesystem"][:url]
  end
  
  test "registers external tools" do
    assert MultiActionAgent.external_tools.key?("browser")
    
    tool = MultiActionAgent.external_tools["browser"]
    assert_equal BrowserAutomation, tool.provider
    assert_equal [:navigate, :click, :screenshot], tool.actions
  end
  
  test "creates methods for external tool actions" do
    assert @agent.respond_to?(:browser_navigate)
    assert @agent.respond_to?(:browser_click)
    assert @agent.respond_to?(:browser_screenshot)
  end
  
  test "executes external tool actions" do
    result = @agent.browser_navigate(url: "https://example.com")
    
    assert_equal "navigate", result[:action]
    assert_equal({ url: "https://example.com" }, result[:params])
    assert_equal "success", result[:result]
  end
  
  test "tracks action execution" do
    # Mock persistence context
    @agent.instance_variable_set(:@_solid_prompt_context,
      SolidAgent::Models::PromptContext.create!(
        agent: SolidAgent::Models::Agent.register(MultiActionAgent)
      )
    )
    
    assert_difference "SolidAgent::Models::ActionExecution.count", 1 do
      @agent.calculate(expression: "2 + 2")
    end
    
    action = SolidAgent::Models::ActionExecution.last
    assert_equal "calculate", action.action_name
    assert_equal "function", action.action_type
    assert_equal({ "expression" => "2 + 2" }, action.parameters)
  end
  
  test "detects action types correctly" do
    assert_equal "function", @agent.send(:detect_action_type_for, "calculate")
    assert_equal "function", @agent.send(:detect_action_type_for, "search_web")
    assert_equal "mcp_tool", @agent.send(:detect_action_type_for, "mcp_filesystem_read")
    assert_equal "tool", @agent.send(:detect_action_type_for, "browser_navigate")
  end
  
  test "generates tool schemas" do
    action = MultiActionAgent.registered_actions[:analyze_sentiment]
    schema = action.to_tool_schema
    
    assert_equal "function", schema[:type]
    assert_equal "analyze_sentiment", schema[:function][:name]
    assert_equal "Analyzes text sentiment", schema[:function][:description]
    assert_equal ["text"], schema[:function][:parameters][:required]
    assert_equal "string", schema[:function][:parameters][:properties][:text][:type]
  end
  
  test "handles action execution errors" do
    @agent.instance_variable_set(:@_solid_prompt_context,
      SolidAgent::Models::PromptContext.create!(
        agent: SolidAgent::Models::Agent.register(MultiActionAgent)
      )
    )
    
    # Define action that raises error
    MultiActionAgent.action :failing_action do
      execute do |params|
        raise StandardError, "Action failed"
      end
    end
    
    assert_difference "SolidAgent::Models::ActionExecution.count", 1 do
      assert_raises StandardError do
        @agent.failing_action
      end
    end
    
    action = SolidAgent::Models::ActionExecution.last
    assert_equal "failed", action.status
    assert_equal "Action failed", action.error_message
  end
  
  test "all_actions returns comprehensive action list" do
    all_actions = MultiActionAgent.all_actions
    
    # Should include all types of actions
    assert all_actions.key?(:calculate)           # Public method
    assert all_actions.key?(:search_web)          # From concern
    assert all_actions.key?(:analyze_sentiment)   # Explicit definition
    # MCP and external tools would be included after connection
  end
end