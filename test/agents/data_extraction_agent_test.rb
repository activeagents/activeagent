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

      assert_equal "The cat in the image is lying on its back on a brown leather surface. It has a primarily white coat with some black patches. Its paws are stretched out, and the cat appears to be comfortably relaxed, with its eyes closed and a peaceful expression. The light from the sun creates a warm glow around it, highlighting its features.", response.message.content
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

      assert response.message.content.include?("John Doe")
      assert response.message.content.include?("Software Engineer")
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
      json_response = JSON.parse(response.message.content)
      # endregion data_extraction_agent_parse_resume_with_structured_output_json
      doc_example_output(response)
      doc_example_output(json_response, "parse-resume-json-response")

      assert_equal "application/json", response.message.content_type
      assert_equal "resume_schema", response.prompt.output_schema["format"]["name"]
      assert_equal json_response["name"], "John Doe"
      assert_equal json_response["email"], "john.doe@example.com"
      assert_equal response.message.content, "{\"name\":\"John Doe\",\"email\":\"john.doe@example.com\",\"phone\":\"(555) 123-4567\",\"education\":[{\"degree\":\"BS Computer Science\",\"institution\":\"Stanford University\",\"year\":2020}],\"experience\":[{\"job_title\":\"Senior Software Engineer\",\"company\":\"TechCorp\",\"duration\":\"2020-2024\"}]}"
      assert response.message.content.include?("John Doe")
      assert response.message.content.include?("Software Engineer")
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

      assert_equal "The image presents a bar chart titled \"Quarterly Sales Report\" for the year 2024. It depicts sales revenue by quarter, with data represented for four quarters (Q1, Q2, Q3, and Q4) using differently colored bars:\n\n- **Q1**: Blue bar\n- **Q2**: Green bar\n- **Q3**: Yellow bar\n- **Q4**: Red bar\n\nThe sales revenue ranges from $0 to $100,000, with each quarter showing varying levels of sales revenue, with Q4 having the highest bar.", response.message.content
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
      json_response = JSON.parse(response.message.content)
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
