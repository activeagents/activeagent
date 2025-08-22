require "test_helper"

class ScrapingAgentMultiturnTest < ActiveSupport::TestCase
  test "scraping agent uses tools to check Google homepage" do
    VCR.use_cassette("scraping_agent_google_check") do
      response = ScrapingAgent.with(
        message: "Are there any notices on the Google homepage?"
      ).prompt_context.generate_now

      # Check we got a response
      assert response.message.present?
      assert response.message.content.present?

      # Check the final message mentions Google/homepage/notices
      assert response.message.content.downcase.include?("google") ||
             response.message.content.downcase.include?("homepage") ||
             response.message.content.downcase.include?("notice"),
        "Response should mention Google, homepage, or notices"

      # Check the message history shows tool usage
      messages = response.prompt.messages

      # Should have system, user, assistant(s), and tool messages
      assert messages.any? { |m| m.role == :system }, "Should have system message"
      assert messages.any? { |m| m.role == :user }, "Should have user message"
      assert messages.any? { |m| m.role == :assistant }, "Should have assistant messages"
      assert messages.any? { |m| m.role == :tool }, "Should have tool messages"

      # Check tool messages have the expected structure
      tool_messages = messages.select { |m| m.role == :tool }
      assert tool_messages.length >= 1, "Should have at least one tool message"

      tool_messages.each do |tool_msg|
        assert tool_msg.action_id.present?, "Tool message should have action_id"
        assert tool_msg.action_name.present?, "Tool message should have action_name"
        assert [ "visit", "read_current_page" ].include?(tool_msg.action_name),
          "Tool name should be visit or read_current_page"
      end

      # Verify specific tools were called
      tool_names = tool_messages.map(&:action_name)
      assert tool_names.include?("visit"), "Should have called visit tool"
      assert tool_names.include?("read_current_page"), "Should have called read_current_page tool"

      # Tool messages in the prompt.messages array show they were executed
      # The actual content is returned separately (not in these tool messages)

      # Generate documentation example
      doc_example_output(response)
    end
  end
end
