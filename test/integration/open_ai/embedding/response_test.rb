# frozen_string_literal: true

require_relative "../../test_helper"

module Integration
  module OpenAI
    module Embedding
      class ResponseTest < ActiveSupport::TestCase
        include Integration::TestHelper

        test "embedding response has correct structure and native response" do
          VCR.use_cassette("integration/open_ai/embedding/response_test/embed") do
            response = ActiveAgent::Providers::OpenAIProvider.new(
              service: "OpenAI",
              model: "text-embedding-3-small",
              input: "Hello world"
            ).embed

            # Validate response structure
            assert_instance_of ActiveAgent::Providers::Common::Responses::Embed, response
            assert response.success?
            assert_not_nil response.raw_response

            # Validate data contains embedding objects
            assert_operator response.data.length, :>, 0
            assert_instance_of Hash, response.data.first
            assert response.data.first[:object].to_s.include?("embedding")
            assert_instance_of Array, response.data.first[:embedding]
            assert_operator response.data.first[:embedding].length, :>, 0
          end
        end
      end
    end
  end
end
