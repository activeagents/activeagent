require "test_helper"

class DataExtractionAgentTest < ActiveSupport::TestCase
  test "describe_cat_image creates a multimodal prompt with image and text content" do
    prompt = nil
    VCR.use_cassette("data_extraction_agent_describe_cat_image") do
      prompt = DataExtractionAgent.describe_cat_image

      assert_equal "multipart/mixed", prompt.content_type
      assert prompt.multimodal?
      assert prompt.message.content.is_a?(Array)
      assert_equal 2, prompt.message.content.size
    end

    VCR.use_cassette("data_extraction_agent_describe_cat_image_generation_response") do
      response = prompt.generate_now

      assert_equal response.message.content, "The cat in the image has a sleek, short coat that appears to be a grayish-brown color. Its eyes are large and striking, with a vivid green hue. The cat is sitting comfortably, being gently petted by a hand that is adorned with a bracelet. Overall, it has a calm and curious expression. The background features a dark, soft surface, adding to the cozy atmosphere of the scene."
    end
  end

  test "parse_resume creates a multimodal prompt with file data" do
    prompt = nil
    VCR.use_cassette("data_extraction_agent_parse_resume") do
      prompt = DataExtractionAgent.with(file_path: Rails.root.join("..", "..", "test", "fixtures", "files", "sample_resume.pdf")).parse_content

      assert_equal "multipart/mixed", prompt.content_type
      assert prompt.multimodal?
      assert prompt.message.content.is_a?(Array)
      assert_equal 2, prompt.message.content.size
    end

    VCR.use_cassette("data_extraction_agent_parse_resume_generation_response") do
      response = prompt.generate_now

      assert response.message.content.include?("John Doe")
      assert response.message.content.include?("Software Engineer")
    end
  end

  test "parse_resume creates a multimodal prompt with file data with structured output schema" do
    prompt = nil
    VCR.use_cassette("data_extraction_agent_parse_resume_with_structured_output") do
      prompt = DataExtractionAgent.with(output_schema: :resume_schema, file_path: Rails.root.join("..", "..", "test", "fixtures", "files", "sample_resume.pdf")).parse_content

      assert_equal "multipart/mixed", prompt.content_type
      assert prompt.multimodal?, "Prompt should be multimodal with file data"
      assert prompt.message.content.is_a?(Array), "Prompt message content should be an array for multimodal support"
      assert_equal 2, prompt.message.content.size
    end

    VCR.use_cassette("data_extraction_agent_parse_resume_generation_response_with_structured_output") do
      response = prompt.generate_now
      json_response = JSON.parse(response.message.content)
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
      prompt = DataExtractionAgent.with(image_path: Rails.root.join("..", "..", "test", "fixtures", "images", "sales_chart.png")).parse_content

      assert_equal "multipart/mixed", prompt.content_type
      assert prompt.multimodal?, "Prompt should be multimodal with image data"
      assert prompt.message.content.is_a?(Array)
      assert_equal 2, prompt.message.content.size
    end

    VCR.use_cassette("data_extraction_agent_parse_chart_generation_response") do
      response = prompt.generate_now

      assert_equal response.message.content, "The graph titled \"Quarterly Sales Report\" displays sales revenue for four quarters in 2024. Key points include:\n\n- **Q1**: Blue bar represents the lowest sales revenue.\n- **Q2**: Green bar shows an increase in sales compared to Q1.\n- **Q3**: Yellow bar continues the upward trend with higher sales than Q2.\n- **Q4**: Red bar indicates the highest sales revenue of the year.\n\nOverall, there is a clear upward trend in sales revenue over the quarters, reaching a peak in Q4."
    end
  end

  test "parse_chart content from image data with structured output schema" do
    prompt = nil
    VCR.use_cassette("data_extraction_agent_parse_chart_with_structured_output") do
      # region data_extraction_agent_parse_chart_with_structured_output
      prompt = DataExtractionAgent.with(
        output_schema: :chart_schema,
        image_path: Rails.root.join("..", "..", "test", "fixtures", "images", "sales_chart.png")
      ).parse_content
      # endregion data_extraction_agent_parse_chart_with_structured_output

      assert_equal "multipart/mixed", prompt.content_type
      assert prompt.multimodal?, "Prompt should be multimodal with image data"
      assert prompt.message.content.is_a?(Array)
      assert_equal 2, prompt.message.content.size
    end

    VCR.use_cassette("data_extraction_agent_parse_chart_generation_response_with_structured_output") do
      response = prompt.generate_now
      
      puts caller.find { |line| line.include?(__FILE__) }
      doc_example_output(response)
      json_response = JSON.parse(response.message.content)
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
