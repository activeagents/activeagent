require "test_helper"

class BrowserAgentTest < ActiveSupport::TestCase
  test "browser agent navigates to a URL using prompt_context" do
    # Skip if Chrome/Cuprite not available
    skip "Cuprite/Chrome not configured for CI" if ENV["CI"]

    VCR.use_cassette("browser_agent_navigate_with_ai") do
      # region navigate_example
      response = BrowserAgent.with(
        message: "Navigate to https://www.example.com and tell me what you see"
      ).prompt_context.generate_now

      assert response.message.content.present?
      # endregion navigate_example

      doc_example_output(response)
    end
  end

  test "browser agent uses actions as tools with AI" do
    skip "Cuprite/Chrome not configured for CI" if ENV["CI"]

    VCR.use_cassette("browser_agent_with_ai") do
      # region ai_browser_example
      response = BrowserAgent.with(
        message: "Go to https://www.example.com and extract the main heading"
      ).prompt_context.generate_now

      # Check that AI used the tools
      assert response.prompt.messages.any? { |m| m.role == :tool }
      assert response.message.content.present?
      # endregion ai_browser_example

      doc_example_output(response)
    end
  end

  test "browser agent can be used directly without AI" do
    skip "Cuprite/Chrome not configured for CI" if ENV["CI"]

    VCR.use_cassette("browser_agent_direct_navigation") do
      # region direct_action_example
      # Call navigate action directly (synchronous execution)
      navigate_response = BrowserAgent.with(
        url: "https://www.example.com"
      ).navigate

      # The action returns a Generation object
      assert_kind_of ActiveAgent::Generation, navigate_response

      # Execute the generation
      result = navigate_response.generate_now

      assert result.message.content.include?("navigated") || result.message.content.include?("Failed") || result.message.content.include?("Example")
      # endregion direct_action_example

      doc_example_output(result)
    end
  end

  test "browser agent researches a topic on Wikipedia" do
    skip "Cuprite/Chrome not configured for CI" if ENV["CI"]

    VCR.use_cassette("browser_agent_wikipedia_research") do
      # region wikipedia_research_example
      response = BrowserAgent.with(
        message: "Research the Apollo 11 moon landing mission. Start at the main Wikipedia article, then:
                  1) Extract the main content to get an overview
                  2) Find and follow links to learn about the crew members (Neil Armstrong, Buzz Aldrin, Michael Collins)
                  3) Take screenshots of important pages
                  4) Extract key dates, mission objectives, and historical significance
                  5) Look for related missions or events by exploring relevant links
                  Please provide a comprehensive summary with details about the mission, crew, and its impact on space exploration.",
        url: "https://en.wikipedia.org/wiki/Apollo_11"
      ).prompt_context.generate_now

      # The agent should navigate to Wikipedia and gather information
      assert response.message.content.present?
      assert response.message.content.downcase.include?("apollo") ||
        response.message.content.downcase.include?("moon") ||
        response.message.content.downcase.include?("armstrong") ||
        response.message.content.downcase.include?("nasa")

      # Check that multiple tools were used
      tool_messages = response.prompt.messages.select { |m| m.role == :tool }
      assert tool_messages.any?, "Should have used tools"

      # Check for variety in tool usage (the agent should use multiple different tools)
      assistant_messages = response.prompt.messages.select { |m| m.role == :assistant }
      tool_names = []
      assistant_messages.each do |msg|
        if msg.requested_actions&.any?
          tool_names.concat(msg.requested_actions.map(&:name))
        end
      end
      tool_names.uniq!

      assert tool_names.length > 2, "Should use at least 3 different tools for comprehensive research"
      # endregion wikipedia_research_example

      doc_example_output(response)
    end
  end

  test "browser agent takes area screenshot" do
    skip "Cuprite/Chrome not configured for CI" if ENV["CI"]

    VCR.use_cassette("browser_agent_area_screenshot") do
      # region area_screenshot_example
      response = BrowserAgent.with(
        message: "Navigate to https://www.example.com and take a screenshot of just the header area (top 200 pixels)"
      ).prompt_context.generate_now

      assert response.message.content.present?

      # Check that screenshot tool was used
      tool_messages = response.prompt.messages.select { |m| m.role == :tool }
      assert tool_messages.any? { |m| m.content.include?("screenshot") }, "Should have taken a screenshot"
      # endregion area_screenshot_example

      doc_example_output(response)
    end
  end

  test "browser agent auto-crops main content" do
    skip "Cuprite/Chrome not configured for CI" if ENV["CI"]

    VCR.use_cassette("browser_agent_main_content_crop") do
      # region main_content_crop_example
      response = BrowserAgent.with(
        message: "Navigate to Wikipedia's Apollo 11 page and take a screenshot of the main content (should automatically exclude navigation/header)"
      ).prompt_context.generate_now

      assert response.message.content.present?

      # Check that screenshot was taken
      tool_messages = response.prompt.messages.select { |m| m.role == :tool }
      assert tool_messages.any? { |m| m.content.include?("screenshot") }, "Should have taken a screenshot"

      # Check that the agent navigated to Wikipedia
      assert tool_messages.any? { |m| m.content.include?("wikipedia") }, "Should have navigated to Wikipedia"
      # endregion main_content_crop_example

      doc_example_output(response)
    end
  end
end
