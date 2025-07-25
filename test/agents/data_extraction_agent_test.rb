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

      assert response.message == "The cat is fluffy and has a playful demeanor."
    end
  end
end