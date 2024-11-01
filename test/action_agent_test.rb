# test/agents/action_agent_test.rb
require_relative "test_helper"

class ActionAgentTest < ActiveSupport::TestCase
  setup do
    @agent = ActionAgent.new
  end

  test "search action returns a prompt with multiple parts" do
    result = @agent.search

    assert_instance_of ActiveAgent::ActionPrompt::Prompt, result
    assert_equal 3, result.parts.size

    text_part = result.parts.find { |part| part.content_type == "text/plain" }
    html_part = result.parts.find { |part| part.content_type == "text/html" }
    json_part = result.parts.find { |part| part.content_type == "application/json" }

    assert_equal "Searching for results...", text_part.body
    assert_equal "<h1>Search Results</h1>", html_part.body
    assert_equal({results: [1, 2, 3]}.to_json, json_part.body)
  end

  test "greet action renders templates" do
    # Assuming you have templates set up in app/views/action_agent/greet.*
    result = @agent.greet("Alice")

    assert_instance_of ActiveAgent::ActionPrompt::Prompt, result
    assert_equal 2, result.parts.size  # Assuming you have text and HTML templates

    text_part = result.parts.find { |part| part.content_type == "text/plain" }
    html_part = result.parts.find { |part| part.content_type == "text/html" }

    assert_match(/Hello, Alice/, text_part.body)
    assert_match(/<h1>Hello, Alice<\/h1>/, html_part.body)
  end
end
