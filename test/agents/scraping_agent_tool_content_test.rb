require "test_helper"

class ScrapingAgentToolContentTest < ActiveSupport::TestCase
  test "tool messages should contain rendered view content" do
    VCR.use_cassette("scraping_agent_tool_content") do
      response = ScrapingAgent.with(
        message: "Check the Google homepage"
      ).prompt_context.generate_now

      # Get tool messages from the response
      tool_messages = response.prompt.messages.select { |m| m.role == :tool }
      
      # We expect tool messages to be present
      assert tool_messages.any?, "Should have tool messages"
      
      # Check each tool message
      tool_messages.each do |tool_msg|
        puts "Tool: #{tool_msg.action_name}"
        puts "Content: '#{tool_msg.content}'"
        puts "Content present?: #{tool_msg.content.present?}"
        
        # FAILING: Tool messages should have the rendered content from their views
        # Currently they have empty content ""
        if tool_msg.action_name == "visit"
          # Should contain "Navigation resulted in 200 status code." from visit.text.erb
          assert tool_msg.content.present?, 
            "Visit tool message should have content from visit.text.erb template"
          assert tool_msg.content.include?("Navigation") || tool_msg.content.include?("200"),
            "Visit tool message should contain rendered template output"
        elsif tool_msg.action_name == "read_current_page"
          # Should contain "Title: Google\nBody: ..." from read_current_page.text.erb  
          assert tool_msg.content.present?,
            "Read tool message should have content from read_current_page.text.erb template"
          assert tool_msg.content.include?("Title:") || tool_msg.content.include?("Body:"),
            "Read tool message should contain rendered template output"
        end
      end
      
      # Also check the raw_request to see what's being sent to OpenAI
      if response.raw_request
        tool_messages_in_request = response.raw_request[:messages].select { |m| m[:role] == "tool" }
        puts "\nTool messages in raw_request:"
        tool_messages_in_request.each do |tool_msg|
          puts "  Tool call ID: #{tool_msg[:tool_call_id]}"
          puts "  Name: #{tool_msg[:name]}"
          puts "  Content: '#{tool_msg[:content]}'"
        end
      end
    end
  end
  
  test "tool action rendering should populate message content" do
    agent = ScrapingAgent.new
    agent.context = ActiveAgent::ActionPrompt::Prompt.new
    
    # Create a mock action
    action = ActiveAgent::ActionPrompt::Action.new(
      id: "test_visit_123",
      name: "visit",
      params: { url: "https://example.com" }
    )
    
    # Perform the action
    agent.send(:perform_action, action)
    
    # Get the tool message that was added
    tool_message = agent.context.messages.last
    
    assert_equal :tool, tool_message.role
    assert_equal "test_visit_123", tool_message.action_id
    assert_equal "visit", tool_message.action_name
    
    # This is the key assertion - the tool message should have the rendered content
    puts "Tool message content: '#{tool_message.content}'"
    assert tool_message.content.present?, 
      "Tool message should have content from the rendered view"
    assert tool_message.content.include?("Navigation resulted in"),
      "Tool message should contain the rendered visit.text.erb template"
  end
end