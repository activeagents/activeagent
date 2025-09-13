require "test_helper"

class PlaywrightStructuredComboTest < ActiveSupport::TestCase
  test "playwright MCP captures content and structured agent extracts data" do
    VCR.use_cassette("playwright_structured_combo") do
      # region playwright_structured_combo_example
      # Step 1: Use Playwright MCP to capture page content
      capture_response = PlaywrightMcpAgent.with(
        url: "https://www.example.com",
        capture_screenshots: false
      ).capture_for_extraction.generate_now

      assert capture_response.message.content.present?
      
      # Step 2: Use StructuredDataAgent to extract structured data
      page_schema = {
        name: "webpage_info",
        strict: true,
        schema: {
          type: "object",
          properties: {
            title: { type: "string" },
            main_heading: { type: "string" },
            links_count: { type: "integer" },
            has_forms: { type: "boolean" },
            main_content_summary: { type: "string" }
          },
          required: ["title", "main_heading", "links_count", "has_forms", "main_content_summary"],
          additionalProperties: false
        }
      }

      extraction_response = StructuredDataAgent.with(
        content: capture_response.message.content,
        schema: page_schema
      ).extract_structured.generate_now

      # Verify structured data was extracted
      assert extraction_response.message.content.is_a?(Hash), "Response should be a Hash"
      assert extraction_response.message.content["title"].present?, "Title should be present"
      # The schema requires all fields, so they should all be present
      assert extraction_response.message.content.key?("main_content_summary"), "Should have main_content_summary key"
      # endregion playwright_structured_combo_example

      doc_example_output(capture_response, "capture")
      doc_example_output(extraction_response, "extraction")
    end
  end

  test "extract product data from e-commerce page using both agents" do
    VCR.use_cassette("playwright_structured_product") do
      # region playwright_structured_product_example
      # Capture product page content
      capture_response = PlaywrightMcpAgent.with(
        url: "https://books.toscrape.com/catalogue/a-light-in-the-attic_1000/index.html"
      ).capture_for_extraction.generate_now

      # Extract structured product data
      product_response = StructuredDataAgent.with(
        page_content: capture_response.message.content,
        url: "https://books.toscrape.com/catalogue/a-light-in-the-attic_1000/index.html"
      ).extract_product_data.generate_now

      assert product_response.message.content.is_a?(Hash)
      assert product_response.message.content["name"].present?
      assert product_response.message.content["price"].present?
      # endregion playwright_structured_product_example

      doc_example_output(product_response)
    end
  end

  test "research topic with MCP then structure findings" do
    VCR.use_cassette("playwright_structured_research") do
      # region playwright_structured_research_example
      # Use Playwright MCP to research a topic
      research_response = PlaywrightMcpAgent.with(
        topic: "Ruby programming language history",
        start_url: "https://en.wikipedia.org/wiki/Ruby_(programming_language)",
        depth: 1,
        max_pages: 3
      ).research_topic.generate_now

      # Structure the research findings
      research_schema = {
        name: "research_findings",
        strict: true,
        schema: {
          type: "object",
          properties: {
            topic: { type: "string" },
            summary: { type: "string" },
            key_facts: {
              type: "array",
              items: { type: "string" }
            },
            important_dates: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  date: { type: "string" },
                  event: { type: "string" }
                },
                required: ["date", "event"],
                additionalProperties: false
              }
            },
            key_people: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  name: { type: "string" },
                  role: { type: "string" }
                },
                required: ["name"],
                additionalProperties: false
              }
            },
            sources: {
              type: "array",
              items: { type: "string" }
            }
          },
          required: ["topic", "summary", "key_facts"],
          additionalProperties: false
        }
      }

      structured_research = StructuredDataAgent.with(
        content: research_response.message.content,
        schema: research_schema,
        instructions: "Extract and structure the research findings about Ruby programming language"
      ).extract_structured.generate_now

      assert structured_research.message.content.is_a?(Hash)
      assert structured_research.message.content["topic"].present?
      assert structured_research.message.content["summary"].present?
      assert structured_research.message.content["key_facts"].is_a?(Array)
      # endregion playwright_structured_research_example

      doc_example_output(structured_research)
    end
  end

  test "compare data from multiple pages" do
    VCR.use_cassette("playwright_structured_compare") do
      # region playwright_structured_compare_example
      # Capture content from two different pages
      page1_response = PlaywrightMcpAgent.with(
        url: "https://www.ruby-lang.org"
      ).capture_for_extraction.generate_now

      page2_response = PlaywrightMcpAgent.with(
        url: "https://www.python.org"
      ).capture_for_extraction.generate_now

      # Compare the two programming language websites
      comparison_response = StructuredDataAgent.with(
        data_sources: [
          { name: "Ruby", content: page1_response.message.content },
          { name: "Python", content: page2_response.message.content }
        ]
      ).compare_data.generate_now

      assert comparison_response.message.content.is_a?(Hash)
      assert comparison_response.message.content["summary"].present?
      assert comparison_response.message.content["differences"].is_a?(Array)
      assert comparison_response.message.content["similarities"].is_a?(Array)
      # endregion playwright_structured_compare_example

      doc_example_output(comparison_response)
    end
  end

  test "extract form structure using both agents" do
    VCR.use_cassette("playwright_structured_form") do
      # region playwright_structured_form_example
      # Navigate to a page with a form
      form_capture = PlaywrightMcpAgent.with(
        url: "https://httpbin.org/forms/post"
      ).capture_for_extraction.generate_now

      # Extract the form structure
      form_structure = StructuredDataAgent.with(
        form_html: form_capture.message.content,
        form_context: "Customer order form from httpbin.org"
      ).extract_form_schema.generate_now

      assert form_structure.message.content.is_a?(Hash)
      assert form_structure.message.content["fields"].is_a?(Array)
      assert form_structure.message.content["fields"].any? { |f| f["type"] == "text" }
      # endregion playwright_structured_form_example

      doc_example_output(form_structure)
    end
  end

  test "use extract_with_structure convenience method" do
    VCR.use_cassette("playwright_extract_with_structure") do
      # region extract_with_structure_example
      # Use the convenience method that combines both agents
      schema = {
        name: "simple_page_data",
        strict: true,
        schema: {
          type: "object",
          properties: {
            title: { type: "string" },
            description: { type: "string" },
            links_count: { type: "integer" }
          },
          required: ["title"],
          additionalProperties: false
        }
      }

      # This method handles both agents internally
      structured_data = PlaywrightMcpAgent.new.extract_with_structure(
        url: "https://www.example.com",
        schema: schema
      )

      assert structured_data.is_a?(Hash)
      assert structured_data["title"].present?
      # endregion extract_with_structure_example

      doc_example_output({ content: structured_data })
    end
  end
end