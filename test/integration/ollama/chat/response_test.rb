# frozen_string_literal: true

require_relative "../../test_helper"

module Integration
  module Ollama
    module Chat
      class ResponseTest < ActiveSupport::TestCase
        include Integration::TestHelper

        class PromptAgent < ActiveAgent::Base
          generate_with :ollama, model: "deepseek-r1:latest"

          def simple_prompt
            prompt(
              messages: [ { role: "user", content: "Say 'test' once." } ]
            )
          end
        end

        test "chat completion response has correct structure and native response" do
          VCR.use_cassette("integration/ollama/chat/response_test/prompt") do
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
