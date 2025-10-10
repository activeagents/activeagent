require "test_helper"

class PlaywrightMcpAgentTest < ActiveSupport::TestCase
  test "playwright MCP agent navigates to a URL and describes content" do
    VCR.use_cassette("playwright_mcp_navigate_describe") do
      # region playwright_navigate_example
      response = PlaywrightMcpAgent.with(
        url: "https://www.example.com",
        task: "Navigate to the page and describe what you see"
      ).browse_web.generate_now

      assert response.message.content.present?
      # Check for MCP tool usage in the response
      if response.prompt.respond_to?(:requested_actions)
        assert response.prompt.requested_actions.any? { |action| 
          action.name.include?("mcp__playwright__browser")
        }
      end
      # endregion playwright_navigate_example

      doc_example_output(response)
    end
  end

  test "playwright MCP agent captures content for extraction" do
    VCR.use_cassette("playwright_mcp_capture_content") do
      # region playwright_capture_content_example
      response = PlaywrightMcpAgent.with(
        url: "https://www.example.com",
        capture_screenshots: false
      ).capture_for_extraction.generate_now

      # Response should contain page content description
      assert response.message.content.present?
      assert response.message.content.downcase.include?("example") ||
             response.message.content.downcase.include?("page") ||
             response.message.content.downcase.include?("content")
      # endregion playwright_capture_content_example

      doc_example_output(response)
    end
  end

  test "playwright MCP agent performs end-to-end testing" do
    VCR.use_cassette("playwright_mcp_e2e_test") do
      # region playwright_e2e_test_example
      response = PlaywrightMcpAgent.with(
        base_url: "https://www.example.com",
        test_steps: [
          "Navigate to the homepage",
          "Verify the page title contains 'Example'",
          "Check that there is at least one link on the page",
          "Take a screenshot for documentation"
        ],
        assertions: [
          "Page loads successfully",
          "Title is correct",
          "Navigation elements are present"
        ]
      ).test_user_flow.generate_now

      assert response.message.content.present?
      
      # Should use multiple MCP tools
      if response.prompt.respond_to?(:requested_actions) && response.prompt.requested_actions
        mcp_actions = response.prompt.requested_actions.select { |a| 
          a.name.include?("mcp__playwright")
        }
        assert mcp_actions.length > 1, "Should use multiple MCP tools for testing"
      end
      # endregion playwright_e2e_test_example

      doc_example_output(response)
    end
  end

  test "playwright MCP agent researches Apollo 11 on Wikipedia" do
    VCR.use_cassette("playwright_mcp_apollo_research") do
      # region playwright_research_example
      response = PlaywrightMcpAgent.with(
        topic: "Apollo 11 moon landing mission",
        start_url: "https://en.wikipedia.org/wiki/Apollo_11",
        depth: 2,
        max_pages: 5
      ).research_topic.generate_now

      # Agent should gather comprehensive information
      assert response.message.content.present?
      assert response.message.content.downcase.include?("apollo") ||
             response.message.content.downcase.include?("moon") ||
             response.message.content.downcase.include?("armstrong")

      # Should navigate to multiple pages
      if response.prompt.respond_to?(:requested_actions) && response.prompt.requested_actions
        navigate_actions = response.prompt.requested_actions.select { |a|
          a.name == "mcp__playwright__browser_navigate"
        }
        assert navigate_actions.length >= 2, "Should navigate to multiple pages for research"
      end
      # endregion playwright_research_example

      doc_example_output(response)
    end
  end

  test "playwright MCP agent fills and submits a form" do
    VCR.use_cassette("playwright_mcp_form_fill") do
      # region playwright_form_fill_example
      response = PlaywrightMcpAgent.with(
        url: "https://httpbin.org/forms/post",
        form_data: {
          custname: "John Doe",
          custtel: "555-1234",
          custemail: "john@example.com",
          size: "large",
          topping: ["bacon", "cheese"],
          delivery: "19:00",
          comments: "Please ring the doorbell twice"
        },
        submit: true
      ).fill_form.generate_now

      assert response.message.content.present?
      
      # Should use form filling tools
      if response.prompt.respond_to?(:requested_actions) && response.prompt.requested_actions
        form_actions = response.prompt.requested_actions.select { |a|
          a.name == "mcp__playwright__browser_fill_form" ||
          a.name == "mcp__playwright__browser_type"
        }
        assert form_actions.any?, "Should use form filling tools"
      end
      # endregion playwright_form_fill_example

      doc_example_output(response)
    end
  end

  test "playwright MCP agent monitors page for changes" do
    VCR.use_cassette("playwright_mcp_monitor") do
      # region playwright_monitor_example
      response = PlaywrightMcpAgent.with(
        url: "https://time.is/",
        wait_for: "time update",
        timeout: 5
      ).monitor_page.generate_now

      assert response.message.content.present?
      
      # Should use wait or monitoring tools
      if response.prompt.respond_to?(:requested_actions) && response.prompt.requested_actions
        wait_actions = response.prompt.requested_actions.select { |a|
          a.name == "mcp__playwright__browser_wait_for" ||
          a.name == "mcp__playwright__browser_snapshot"
        }
        assert wait_actions.any?, "Should use monitoring tools"
      end
      # endregion playwright_monitor_example

      doc_example_output(response)
    end
  end

  test "playwright MCP agent performs visual comparison" do
    VCR.use_cassette("playwright_mcp_visual_compare") do
      # region playwright_visual_compare_example
      response = PlaywrightMcpAgent.with(
        urls: [
          "https://www.example.com",
          "https://www.example.org"
        ],
        full_page: true
      ).visual_comparison.generate_now

      assert response.message.content.present?
      
      # Should take screenshots of both pages
      if response.prompt.respond_to?(:requested_actions) && response.prompt.requested_actions
        screenshot_actions = response.prompt.requested_actions.select { |a|
          a.name == "mcp__playwright__browser_take_screenshot"
        }
        assert screenshot_actions.length >= 2, "Should take screenshots of multiple pages"
      end
      # endregion playwright_visual_compare_example

      doc_example_output(response)
    end
  end

  test "playwright MCP agent crawls a website" do
    VCR.use_cassette("playwright_mcp_crawl_site") do
      # region playwright_crawl_example
      response = PlaywrightMcpAgent.with(
        start_url: "https://docs.activeagents.ai",
        pattern: "/docs/",
        max_depth: 2,
        max_pages: 10
      ).crawl_site.generate_now

      assert response.message.content.present?
      
      # Should navigate and analyze multiple pages
      if response.prompt.respond_to?(:requested_actions) && response.prompt.requested_actions
        mcp_actions = response.prompt.requested_actions.select { |a|
          a.name.include?("mcp__playwright")
        }
        assert mcp_actions.length > 3, "Should perform multiple browser actions while crawling"
      end
      # endregion playwright_crawl_example

      doc_example_output(response)
    end
  end

  test "playwright MCP agent handles complex multi-step automation" do
    VCR.use_cassette("playwright_mcp_complex_automation") do
      # region playwright_complex_automation_example
      response = PlaywrightMcpAgent.with(
        task: "1. Go to https://en.wikipedia.org/wiki/Ruby_(programming_language)
               2. Take a screenshot of the main content
               3. Find and click on the 'Rails framework' link
               4. Extract information about Ruby on Rails
               5. Navigate back to the Ruby page
               6. Find links to other programming languages
               7. Visit at least 2 other language pages and compare them to Ruby
               8. Provide a summary comparing Ruby with the other languages",
        screenshot: true
      ).browse_web.generate_now

      assert response.message.content.present?
      
      # Should use various MCP tools
      if response.prompt.respond_to?(:requested_actions) && response.prompt.requested_actions
        tool_types = response.prompt.requested_actions.map(&:name).uniq
        mcp_tools = tool_types.select { |t| t.include?("mcp__playwright") }
        
        assert mcp_tools.length >= 3, "Should use at least 3 different MCP tools"
        
        # Should include navigation, screenshots, and content extraction
        assert tool_types.include?("mcp__playwright__browser_navigate")
        assert tool_types.include?("mcp__playwright__browser_click") ||
               tool_types.include?("mcp__playwright__browser_snapshot")
      end
      # endregion playwright_complex_automation_example

      doc_example_output(response)
    end
  end

  test "playwright MCP agent with direct action calls" do
    VCR.use_cassette("playwright_mcp_direct_action") do
      # region playwright_direct_action_example
      # Direct action call returns a Generation object
      generation = PlaywrightMcpAgent.with(
        url: "https://www.ruby-lang.org",
        task: "Navigate and describe the main features"
      ).browse_web

      # Verify it's a Generation object before executing
      assert_kind_of ActiveAgent::Generation, generation

      # Execute the generation
      response = generation.generate_now

      assert response.message.content.present?
      assert response.message.content.downcase.include?("ruby") ||
             response.message.content.downcase.include?("programming") ||
             response.message.content.downcase.include?("language")
      # endregion playwright_direct_action_example

      doc_example_output(response)
    end
  end
end