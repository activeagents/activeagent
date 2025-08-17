# frozen_string_literal: true

require "test_helper"
require "active_agent/action_prompt/action"
require "active_agent/generation_provider/tool_management"

class ToolManagementTest < ActiveSupport::TestCase
  class TestProvider
    include ActiveAgent::GenerationProvider::ToolManagement
  end

  setup do
    @provider = TestProvider.new
  end

  test "format_tools returns nil for blank tools" do
    assert_nil @provider.format_tools(nil)
    assert_nil @provider.format_tools([])
  end

  test "format_tools formats array of tools" do
    tools = [
      { "name" => "tool1", "description" => "First tool", "parameters" => {} },
      { "name" => "tool2", "description" => "Second tool", "parameters" => {} }
    ]

    formatted = @provider.format_tools(tools)

    assert_equal 2, formatted.length
    assert_equal "function", formatted[0][:type]
    assert_equal "tool1", formatted[0][:function][:name]
    assert_equal "tool2", formatted[1][:function][:name]
  end

  test "format_single_tool handles already formatted tool" do
    tool = {
      "function" => {
        "name" => "existing_tool",
        "description" => "Already formatted",
        "parameters" => { "type" => "object" }
      }
    }

    result = @provider.send(:format_single_tool, tool)
    assert_equal tool, result
  end

  test "format_single_tool handles symbol keys" do
    tool = {
      function: {
        name: "symbol_tool",
        description: "Tool with symbols",
        parameters: {}
      }
    }

    result = @provider.send(:format_single_tool, tool)
    assert_equal tool, result
  end

  test "wrap_tool_in_function creates OpenAI function format" do
    tool = {
      "name" => "my_tool",
      "description" => "Tool description",
      "parameters" => { "type" => "object", "properties" => {} }
    }

    wrapped = @provider.send(:wrap_tool_in_function, tool)

    assert_equal "function", wrapped[:type]
    assert_equal "my_tool", wrapped[:function][:name]
    assert_equal "Tool description", wrapped[:function][:description]
    assert_equal({ "type" => "object", "properties" => {} }, wrapped[:function][:parameters])
  end

  test "wrap_tool_in_function handles symbol keys" do
    tool = {
      name: "symbol_tool",
      description: "Symbol description",
      parameters: { type: "object" }
    }

    wrapped = @provider.send(:wrap_tool_in_function, tool)

    assert_equal "symbol_tool", wrapped[:function][:name]
    assert_equal "Symbol description", wrapped[:function][:description]
  end

  test "handle_actions returns empty array for nil or empty tool_calls" do
    assert_equal [], @provider.handle_actions(nil)
    assert_equal [], @provider.handle_actions([])
  end

  test "handle_actions parses multiple tool calls" do
    tool_calls = [
      {
        "id" => "call_1",
        "function" => {
          "name" => "tool1",
          "arguments" => '{"param":"value1"}'
        }
      },
      {
        "id" => "call_2",
        "function" => {
          "name" => "tool2",
          "arguments" => '{"param":"value2"}'
        }
      }
    ]

    actions = @provider.handle_actions(tool_calls)

    assert_equal 2, actions.length
    assert_equal "call_1", actions[0].id
    assert_equal "tool1", actions[0].name
    assert_equal({ param: "value1" }, actions[0].params)
    assert_equal "call_2", actions[1].id
    assert_equal "tool2", actions[1].name
    assert_equal({ param: "value2" }, actions[1].params)
  end

  test "parse_tool_call returns nil for nil input" do
    assert_nil @provider.send(:parse_tool_call, nil)
  end

  test "parse_tool_call returns nil for tool without name" do
    tool_call = { "id" => "123", "function" => { "arguments" => "{}" } }
    assert_nil @provider.send(:parse_tool_call, tool_call)
  end

  test "parse_tool_call creates Action from tool call" do
    tool_call = {
      "id" => "call_xyz",
      "function" => {
        "name" => "get_weather",
        "arguments" => '{"location":"Paris","units":"celsius"}'
      }
    }

    action = @provider.send(:parse_tool_call, tool_call)

    assert_instance_of ActiveAgent::ActionPrompt::Action, action
    assert_equal "call_xyz", action.id
    assert_equal "get_weather", action.name
    assert_equal({ location: "Paris", units: "celsius" }, action.params)
  end

  test "extract_tool_id gets id from various formats" do
    assert_equal "123", @provider.send(:extract_tool_id, { "id" => "123" })
    assert_equal "456", @provider.send(:extract_tool_id, { id: "456" })
    assert_nil @provider.send(:extract_tool_id, {})
  end

  test "extract_tool_name tries multiple paths" do
    # Function path with string keys
    assert_equal "tool1", @provider.send(:extract_tool_name, {
      "function" => { "name" => "tool1" }
    })

    # Function path with symbol keys
    assert_equal "tool2", @provider.send(:extract_tool_name, {
      function: { name: "tool2" }
    })

    # Direct name with string key
    assert_equal "tool3", @provider.send(:extract_tool_name, { "name" => "tool3" })

    # Direct name with symbol key
    assert_equal "tool4", @provider.send(:extract_tool_name, { name: "tool4" })
  end

  test "extract_tool_params tries multiple paths" do
    # Function arguments path
    tool_call = { "function" => { "arguments" => '{"a":1}' } }
    assert_equal({ a: 1 }, @provider.send(:extract_tool_params, tool_call))

    # Direct arguments
    tool_call = { "arguments" => '{"b":2}' }
    assert_equal({ b: 2 }, @provider.send(:extract_tool_params, tool_call))

    # Input field (Anthropic style)
    tool_call = { "input" => { c: 3 } }
    assert_equal({ c: 3 }, @provider.send(:extract_tool_params, tool_call))

    # Symbol keys
    tool_call = { function: { arguments: '{"d":4}' } }
    assert_equal({ d: 4 }, @provider.send(:extract_tool_params, tool_call))
  end

  test "extract_tool_params handles non-JSON string params" do
    tool_call = { "function" => { "arguments" => "not json" } }
    assert_nil @provider.send(:extract_tool_params, tool_call)
  end

  test "extract_tool_params handles already parsed params" do
    tool_call = { "function" => { "arguments" => { e: 5 } } }
    assert_equal({ e: 5 }, @provider.send(:extract_tool_params, tool_call))
  end

  test "extract_tool_params returns nil for blank arguments" do
    assert_nil @provider.send(:extract_tool_params, { "function" => { "arguments" => "" } })
    assert_nil @provider.send(:extract_tool_params, { "function" => {} })
    assert_nil @provider.send(:extract_tool_params, {})
  end

  test "format_tools_for_anthropic creates Anthropic format" do
    tools = [
      {
        "function" => {
          "name" => "search",
          "description" => "Search the web",
          "parameters" => { "type" => "object" }
        }
      }
    ]

    formatted = @provider.send(:format_tools_for_anthropic, tools)

    assert_equal 1, formatted.length
    assert_equal "search", formatted[0][:name]
    assert_equal "Search the web", formatted[0][:description]
    assert_equal({ "type" => "object" }, formatted[0][:input_schema])
  end

  test "format_tools_for_openai delegates to format_tools" do
    tools = [ { "name" => "tool1", "parameters" => {} } ]

    openai_format = @provider.send(:format_tools_for_openai, tools)
    default_format = @provider.format_tools(tools)

    assert_equal default_format, openai_format
  end

  test "extract helpers work with nested symbol and string keys" do
    mixed_tool = {
      "name" => "direct_name",
      function: {
        "name" => "function_name",
        description: "Mixed keys",
        "parameters" => { type: "object" }
      }
    }

    # Extract tool name should get direct name first, then function name
    # Based on the implementation, it tries "name" first
    assert_equal "direct_name", @provider.send(:extract_tool_name_from_schema, mixed_tool)
    assert_equal "Mixed keys", @provider.send(:extract_tool_description_from_schema, mixed_tool)
    # The function key is a symbol, so tool.dig(:function, :parameters) will find it
    assert_equal({ type: "object" }, @provider.send(:extract_tool_parameters_from_schema, mixed_tool))
  end

  test "handle_actions filters out nil results from parse_tool_call" do
    tool_calls = [
      { "id" => "1", "function" => { "name" => "valid", "arguments" => "{}" } },
      { "id" => "2", "function" => {} }, # No name, will return nil
      { "id" => "3", "function" => { "name" => "also_valid", "arguments" => "{}" } }
    ]

    actions = @provider.handle_actions(tool_calls)

    assert_equal 2, actions.length
    assert_equal "valid", actions[0].name
    assert_equal "also_valid", actions[1].name
  end
end
