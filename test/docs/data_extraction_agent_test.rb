require "test_helper"

class DataExtractionAgentTest < ActiveSupport::TestCase
  test "describe_cat_image creates a multimodal prompt with image and text content" do
    prompt = nil
    VCR.use_cassette("data_extraction_agent_describe_cat_image") do
      # region data_extraction_agent_describe_cat_image
      prompt = DataExtractionAgent.describe_cat_image
      # endregion data_extraction_agent_describe_cat_image

      assert_equal "multipart/mixed", prompt.content_type
      assert prompt.multimodal?
      assert prompt.message.content.is_a?(Array)
      assert_equal 2, prompt.message.content.size
    end

    VCR.use_cassette("data_extraction_agent_describe_cat_image_generation_response") do
      # region data_extraction_agent_describe_cat_image_response
      response = prompt.generate_now
      # endregion data_extraction_agent_describe_cat_image_response
      doc_example_output(response)
      expected_response = "The cat in the image appears to have a primarily dark gray coat with a white patch on its chest. It has a curious expression and is positioned in a relaxed manner. The background suggests a cozy indoor environment, possibly with soft bedding and other household items visible."
      assert_equal expected_response, response.message.content
    end
  end

  test "parse_resume creates a multimodal prompt with file data" do
    prompt = nil
    VCR.use_cassette("data_extraction_agent_parse_resume") do
      sample_resume_path = Rails.root.join("..", "..", "test", "fixtures", "files", "sample_resume.pdf")
      # region data_extraction_agent_parse_resume
      prompt = DataExtractionAgent.with(
        output_schema: :resume_schema,
        file_path: sample_resume_path
      ).parse_content
      # endregion data_extraction_agent_parse_resume

      assert_equal "multipart/mixed", prompt.content_type
      assert prompt.multimodal?
      assert prompt.message.content.is_a?(Array)
      assert_equal 2, prompt.message.content.size
    end

    VCR.use_cassette("data_extraction_agent_parse_resume_generation_response") do
      response = prompt.generate_now
      doc_example_output(response)

      # When output_schema IS present (:resume_schema), content is auto-parsed
      assert response.message.content.is_a?(Hash)
      assert response.message.content["name"].include?("John Doe")
      assert response.message.content["experience"].any? { |exp| exp["job_title"].include?("Software Engineer") }
    end
  end

  test "parse_resume creates a multimodal prompt with file data with structured output schema" do
    prompt = nil
    VCR.use_cassette("data_extraction_agent_parse_resume_with_structured_output") do
      # region data_extraction_agent_parse_resume_with_structured_output
      prompt = DataExtractionAgent.with(
        output_schema: :resume_schema,
        file_path: Rails.root.join("..", "..", "test", "fixtures", "files", "sample_resume.pdf")
      ).parse_content
      # endregion data_extraction_agent_parse_resume_with_structured_output

      assert_equal "multipart/mixed", prompt.content_type
      assert prompt.multimodal?, "Prompt should be multimodal with file data"
      assert prompt.message.content.is_a?(Array), "Prompt message content should be an array for multimodal support"
      assert_equal 2, prompt.message.content.size
    end

    VCR.use_cassette("data_extraction_agent_parse_resume_generation_response_with_structured_output") do
      # region data_extraction_agent_parse_resume_with_structured_output_response
      response = prompt.generate_now
      # endregion data_extraction_agent_parse_resume_with_structured_output_response
      # region data_extraction_agent_parse_resume_with_structured_output_json
      # When output_schema is present, content is already parsed
      json_response = response.message.content
      # endregion data_extraction_agent_parse_resume_with_structured_output_json
      doc_example_output(response)
      doc_example_output(json_response, "parse-resume-json-response")

      assert_equal "application/json", response.message.content_type
      assert_equal "resume_schema", response.prompt.output_schema["format"]["name"]
      assert_equal json_response["name"], "John Doe"
      assert_equal json_response["email"], "john.doe@example.com"
      # Verify raw_content contains the JSON string
      assert_equal response.message.raw_content, "{\"name\":\"John Doe\",\"email\":\"john.doe@example.com\",\"phone\":\"(555) 123-4567\",\"education\":[{\"degree\":\"BS Computer Science\",\"institution\":\"Stanford University\",\"year\":2020}],\"experience\":[{\"job_title\":\"Senior Software Engineer\",\"company\":\"TechCorp\",\"duration\":\"2020-2024\"}]}"
      # Verify parsed content
      assert json_response["name"].include?("John Doe")
      assert json_response["experience"].any? { |exp| exp["job_title"].include?("Software Engineer") }
    end
  end

  test "parse_chart content from image data" do
    prompt = nil
    VCR.use_cassette("data_extraction_agent_parse_chart") do
      sales_chart_path = Rails.root.join("..", "..", "test", "fixtures", "images", "sales_chart.png")
      # region data_extraction_agent_parse_chart
      prompt = DataExtractionAgent.with(
        image_path: sales_chart_path
      ).parse_content
      # endregion data_extraction_agent_parse_chart

      assert_equal "multipart/mixed", prompt.content_type
      assert prompt.multimodal?, "Prompt should be multimodal with image data"
      assert prompt.message.content.is_a?(Array)
      assert_equal 2, prompt.message.content.size
    end

    VCR.use_cassette("data_extraction_agent_parse_chart_generation_response") do
      response = prompt.generate_now
      doc_example_output(response)
      expected_response = "The image is a bar chart titled \"Quarterly Sales Report\" that displays sales revenue for the year 2024 by quarter. \n\n- **Y-axis** represents sales revenue in thousands of dollars, ranging from $0 to $100,000.\n- **X-axis** lists the four quarters: Q1, Q2, Q3, and Q4.\n\nThe bars are colored as follows:\n- Q1: Blue\n- Q2: Green\n- Q3: Yellow\n- Q4: Red\n\nThe heights of the bars indicate the sales revenue for each quarter, with Q4 showing the highest revenue."
      assert_equal expected_response, response.message.content
    end
  end

  test "parse_chart content from image data with structured output schema" do
    prompt = nil
    VCR.use_cassette("data_extraction_agent_parse_chart_with_structured_output") do
      sales_chart_path = Rails.root.join("..", "..", "test", "fixtures", "images", "sales_chart.png")
      # region data_extraction_agent_parse_chart_with_structured_output
      prompt = DataExtractionAgent.with(
        output_schema: :chart_schema,
        image_path: sales_chart_path
      ).parse_content
      # endregion data_extraction_agent_parse_chart_with_structured_output

      assert_equal "multipart/mixed", prompt.content_type
      assert prompt.multimodal?, "Prompt should be multimodal with image data"
      assert prompt.message.content.is_a?(Array)
      assert_equal 2, prompt.message.content.size
    end

    VCR.use_cassette("data_extraction_agent_parse_chart_generation_response_with_structured_output") do
      # region data_extraction_agent_parse_chart_with_structured_output_response
      response = prompt.generate_now
      # endregion data_extraction_agent_parse_chart_with_structured_output_response

      # region data_extraction_agent_parse_chart_with_structured_output_json
      # When output_schema is present, content is already parsed
      json_response = response.message.content
      # endregion data_extraction_agent_parse_chart_with_structured_output_json

      doc_example_output(response)
      doc_example_output(json_response, "parse-chart-json-response")
      assert_equal "application/json", response.message.content_type

      assert_equal "chart_schema", response.prompt.output_schema["format"]["name"]

      assert_equal json_response["title"], "Quarterly Sales Report"
      assert json_response["data_points"].is_a?(Array), "Data points should be an array"
      assert_equal json_response["data_points"].first["label"], "Q1"
      assert_equal json_response["data_points"].first["value"], 25000
      assert_equal json_response["data_points"][1]["label"], "Q2"
      assert_equal json_response["data_points"][1]["value"], 50000
      assert_equal json_response["data_points"][2]["label"], "Q3"
      assert_equal json_response["data_points"][2]["value"], 75000
      assert_equal json_response["data_points"].last["label"], "Q4"
      assert_equal json_response["data_points"].last["value"], 100000
    end
  end
end
