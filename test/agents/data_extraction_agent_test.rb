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
end