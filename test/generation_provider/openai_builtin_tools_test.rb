require "test_helper"
require "active_agent/action_prompt/prompt"
require "active_agent/generation_provider/open_ai_provider"

class OpenAIBuiltinToolsTest < ActiveSupport::TestCase
  setup do
    @config = {
      "model" => "gpt-5",
      "api_key" => "test-key"
    }
    @provider = ActiveAgent::GenerationProvider::OpenAIProvider.new(@config)
    @prompt = ActiveAgent::ActionPrompt::Prompt.new
  end

  test "builds tools array with web_search_preview" do
    @prompt.options = {
      tools: [
        {type: "web_search_preview"}
      ]
    }
    @prompt.actions = []
    
    @provider.instance_variable_set(:@prompt, @prompt)
    tools = @provider.send(:build_tools_for_responses, [])
    
    assert_equal 1, tools.length
    assert_equal "web_search_preview", tools[0][:type]
  end

  test "builds tools array with web_search_preview and options" do
    @prompt.options = {
      tools: [
        {
          type: "web_search_preview",
          search_context_size: "high",
          user_location: {
            type: "approximate",
            country: "US",
            city: "San Francisco"
          }
        }
      ]
    }
    @prompt.actions = []
    
    @provider.instance_variable_set(:@prompt, @prompt)
    tools = @provider.send(:build_tools_for_responses, [])
    
    assert_equal 1, tools.length
    assert_equal "web_search_preview", tools[0][:type]
    assert_equal "high", tools[0][:search_context_size]
    assert_equal({type: "approximate", country: "US", city: "San Francisco"}, tools[0][:user_location])
  end

  test "builds tools array with image_generation" do
    @prompt.options = {
      tools: [
        {type: "image_generation"}
      ]
    }
    @prompt.actions = []
    
    @provider.instance_variable_set(:@prompt, @prompt)
    tools = @provider.send(:build_tools_for_responses, [])
    
    assert_equal 1, tools.length
    assert_equal "image_generation", tools[0][:type]
  end

  test "builds tools array with image_generation and options" do
    @prompt.options = {
      tools: [
        {
          type: "image_generation",
          size: "1024x1024",
          quality: "high",
          format: "png",
          compression: 80,
          background: "transparent",
          partial_images: 2
        }
      ]
    }
    @prompt.actions = []
    
    @provider.instance_variable_set(:@prompt, @prompt)
    tools = @provider.send(:build_tools_for_responses, [])
    
    assert_equal 1, tools.length
    assert_equal "image_generation", tools[0][:type]
    assert_equal "1024x1024", tools[0][:size]
    assert_equal "high", tools[0][:quality]
    assert_equal "png", tools[0][:format]
    assert_equal 80, tools[0][:compression]
    assert_equal "transparent", tools[0][:background]
    assert_equal 2, tools[0][:partial_images]
  end

  test "builds tools array with MCP server" do
    @prompt.options = {
      tools: [
        {
          type: "mcp",
          server_label: "dmcp",
          server_description: "A Dungeons and Dragons MCP server",
          server_url: "https://dmcp-server.deno.dev/sse",
          require_approval: "never"
        }
      ]
    }
    @prompt.actions = []
    
    @provider.instance_variable_set(:@prompt, @prompt)
    tools = @provider.send(:build_tools_for_responses, [])
    
    assert_equal 1, tools.length
    assert_equal "mcp", tools[0][:type]
    assert_equal "dmcp", tools[0][:server_label]
    assert_equal "A Dungeons and Dragons MCP server", tools[0][:server_description]
    assert_equal "https://dmcp-server.deno.dev/sse", tools[0][:server_url]
    assert_equal "never", tools[0][:require_approval]
  end

  test "builds tools array with MCP connector" do
    @prompt.options = {
      tools: [
        {
          type: "mcp",
          server_label: "Dropbox",
          connector_id: "connector_dropbox",
          authorization: "oauth_token_here",
          require_approval: "always",
          allowed_tools: ["search", "fetch"]
        }
      ]
    }
    @prompt.actions = []
    
    @provider.instance_variable_set(:@prompt, @prompt)
    tools = @provider.send(:build_tools_for_responses, [])
    
    assert_equal 1, tools.length
    assert_equal "mcp", tools[0][:type]
    assert_equal "Dropbox", tools[0][:server_label]
    assert_equal "connector_dropbox", tools[0][:connector_id]
    assert_equal "oauth_token_here", tools[0][:authorization]
    assert_equal "always", tools[0][:require_approval]
    assert_equal ["search", "fetch"], tools[0][:allowed_tools]
  end

  test "combines action tools with built-in tools" do
    action_tool = {
      "type" => "function",
      "function" => {
        "name" => "get_weather",
        "description" => "Get the weather",
        "parameters" => {}
      }
    }
    
    @prompt.options = {
      tools: [
        {type: "web_search_preview"},
        {type: "image_generation"}
      ]
    }
    @prompt.actions = [action_tool]
    
    @provider.instance_variable_set(:@prompt, @prompt)
    tools = @provider.send(:build_tools_for_responses, [action_tool])
    
    assert_equal 3, tools.length
    # First should be the action tool
    assert_equal "function", tools[0]["type"]
    assert_equal "get_weather", tools[0]["function"]["name"]
    # Then the built-in tools
    assert_equal "web_search_preview", tools[1][:type]
    assert_equal "image_generation", tools[2][:type]
  end

  test "handles multiple built-in tools" do
    @prompt.options = {
      tools: [
        {type: "web_search_preview", search_context_size: "low"},
        {type: "image_generation", size: "512x512"},
        {
          type: "mcp",
          server_label: "test",
          server_url: "https://test.com/mcp"
        }
      ]
    }
    @prompt.actions = []
    
    @provider.instance_variable_set(:@prompt, @prompt)
    tools = @provider.send(:build_tools_for_responses, [])
    
    assert_equal 3, tools.length
    assert_equal "web_search_preview", tools[0][:type]
    assert_equal "low", tools[0][:search_context_size]
    assert_equal "image_generation", tools[1][:type]
    assert_equal "512x512", tools[1][:size]
    assert_equal "mcp", tools[2][:type]
    assert_equal "test", tools[2][:server_label]
    assert_equal "https://test.com/mcp", tools[2][:server_url]
  end

  test "handles empty tools option" do
    @prompt.options = {}
    @prompt.actions = []
    
    @provider.instance_variable_set(:@prompt, @prompt)
    tools = @provider.send(:build_tools_for_responses, [])
    
    assert_equal 0, tools.length
  end

  test "handles nil action tools" do
    @prompt.options = {
      tools: [{type: "web_search_preview"}]
    }
    @prompt.actions = nil
    
    @provider.instance_variable_set(:@prompt, @prompt)
    tools = @provider.send(:build_tools_for_responses, nil)
    
    assert_equal 1, tools.length
    assert_equal "web_search_preview", tools[0][:type]
  end

  test "ignores invalid tool types" do
    @prompt.options = {
      tools: [
        {type: "invalid_tool"},
        {type: "web_search_preview"}
      ]
    }
    @prompt.actions = []
    
    @provider.instance_variable_set(:@prompt, @prompt)
    tools = @provider.send(:build_tools_for_responses, [])
    
    # Should only include the valid web_search_preview tool
    assert_equal 1, tools.length
    assert_equal "web_search_preview", tools[0][:type]
  end

  test "handles non-hash tool entries" do
    @prompt.options = {
      tools: [
        "not_a_hash",
        {type: "web_search_preview"},
        nil
      ]
    }
    @prompt.actions = []
    
    @provider.instance_variable_set(:@prompt, @prompt)
    tools = @provider.send(:build_tools_for_responses, [])
    
    # Should only include the valid tool
    assert_equal 1, tools.length
    assert_equal "web_search_preview", tools[0][:type]
  end

  test "normalizes web_search to web_search_preview" do
    @prompt.options = {
      tools: [
        {type: "web_search", search_context_size: "medium"}
      ]
    }
    @prompt.actions = []
    
    @provider.instance_variable_set(:@prompt, @prompt)
    tools = @provider.send(:build_tools_for_responses, [])
    
    assert_equal 1, tools.length
    assert_equal "web_search_preview", tools[0][:type]
    assert_equal "medium", tools[0][:search_context_size]
  end
end