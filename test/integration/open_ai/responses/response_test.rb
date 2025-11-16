# frozen_string_literal: true

require_relative "../../test_helper"

module Integration
  module OpenAI
    module Responses
      class ResponseTest < ActiveSupport::TestCase
        include Integration::TestHelper

        class PromptAgent < ActiveAgent::Base
          generate_with :openai,
            model: "gpt-4o-mini",
            modalities: [ "text" ],
            audio: { voice: "alloy", format: "wav" }

          def simple_prompt
            prompt(
              messages: [ { role: "user", content: "Say 'test' once." } ],
              max_completion_tokens: 10
            )
          end
        end

        test "responses api response has correct structure and native response" do
          VCR.use_cassette("integration/open_ai/responses/response_test/prompt") do
            response = PromptAgent.simple_prompt.generate_now

            # Validate response structure
            assert_instance_of ActiveAgent::Providers::Common::Responses::Prompt, response
            assert response.success?
            assert_not_nil response.raw_response

            # Validate messages
            assert_operator response.messages.length, :>, 0
            assert_instance_of ActiveAgent::Providers::Common::Messages::Assistant, response.message
          end
        end
      end
    end
  end
end
