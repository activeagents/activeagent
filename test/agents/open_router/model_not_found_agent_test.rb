require "test_helper"

module OpenRouter
  class ModelNotFoundTest < ActiveSupport::TestCase
    VCR_FOLDER = "open_router/model_not_found_agent"

    # Currently not certain about what set of conditions with models and files
    # trigger this "Model Not Found" error. The error message itself seems to be
    # incorrect.
    test "throw error when output schema not found" do
      VCR.use_cassette("#{VCR_FOLDER}") do
        assert_raises(ActiveAgent::Errors::ProviderApiError) do
          OpenRouter::ModelNotFoundAgent.with(
            output_schema: :non_existent_schema
          ).describe_cat_image.generate_now
        end
      end
    end
  end
end
