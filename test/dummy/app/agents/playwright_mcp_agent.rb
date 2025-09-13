# frozen_string_literal: true

class PlaywrightMcpAgent < ApplicationAgent
  # Configure AI provider for intelligent browser automation using MCP
  # Using GPT-4o-mini for structured output support
  generate_with :openai,
    model: "gpt-4o-mini"

  # Navigate and interact with web pages using Playwright MCP
  def browse_web
    @url = params[:url]
    @task = params[:task]
    @screenshot = params[:screenshot] || false

    prompt(
      mcp_servers: ["playwright"],
      instructions: { template: "browser_automation" }
    )
  end

  # Navigate to page and capture content for structured extraction
  def capture_for_extraction
    @url = params[:url]
    @capture_screenshots = params[:capture_screenshots] || false

    prompt(
      mcp_servers: ["playwright"],
      instructions: { template: "capture_content" }
    )
  end

  # Extract structured data using a two-agent approach
  def extract_with_structure
    @url = params[:url]
    @schema = params[:schema]

    # First, capture the page content using MCP tools
    capture_response = PlaywrightMcpAgent.with(
      url: @url,
      capture_screenshots: false
    ).capture_for_extraction.generate_now

    # Then use StructuredDataAgent to extract structured data
    extraction_response = StructuredDataAgent.with(
      content: capture_response.message.content,
      schema: @schema
    ).extract_structured.generate_now

    # Return the structured data
    extraction_response.message.content
  end

  # Perform end-to-end testing
  def test_user_flow
    @base_url = params[:base_url]
    @test_steps = params[:test_steps]
    @assertions = params[:assertions]

    prompt(
      mcp_servers: ["playwright"],
      instructions: { template: "e2e_testing" }
    )
  end

  # Research a topic across multiple pages
  def research_topic
    @topic = params[:topic]
    @start_url = params[:start_url]
    @depth = params[:depth] || 3
    @max_pages = params[:max_pages] || 10

    prompt(
      mcp_servers: ["playwright"],
      instructions: { template: "research" }
    )
  end

  # Fill and submit forms
  def fill_form
    @url = params[:url]
    @form_data = params[:form_data]
    @submit = params[:submit] != false

    prompt(
      mcp_servers: ["playwright"],
      instructions: { template: "form_filling" }
    )
  end

  # Monitor page for changes
  def monitor_page
    @url = params[:url]
    @wait_for = params[:wait_for]
    @timeout = params[:timeout] || 30

    prompt(
      mcp_servers: ["playwright"],
      instructions: { template: "monitoring" }
    )
  end

  # Compare pages visually
  def visual_comparison
    @urls = params[:urls]
    @full_page = params[:full_page] || false

    prompt(
      mcp_servers: ["playwright"],
      instructions: { template: "visual_diff" }
    )
  end

  # Extract and follow links intelligently
  def crawl_site
    @start_url = params[:start_url]
    @pattern = params[:pattern]
    @max_depth = params[:max_depth] || 2
    @max_pages = params[:max_pages] || 20

    prompt(
      mcp_servers: ["playwright"],
      instructions: { template: "crawling" }
    )
  end
end
