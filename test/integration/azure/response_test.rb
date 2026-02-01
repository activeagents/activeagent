# frozen_string_literal: true

require_relative "../test_helper"

module Integration
  module Azure
    class ResponseTest < ActiveSupport::TestCase
      include Integration::TestHelper

      # Azure requires these environment variables:
      # - AZURE_OPENAI_API_KEY: Your Azure OpenAI API key
      # - AZURE_OPENAI_RESOURCE: Your Azure resource name (e.g., "mycompany")
      # - AZURE_OPENAI_DEPLOYMENT_ID: Your deployment name (e.g., "gpt-4-deployment")

      class PromptAgent < ActiveAgent::Base
        generate_with :azure_openai,
          api_key: ENV["AZURE_OPENAI_API_KEY"],
          azure_resource: ENV["AZURE_OPENAI_RESOURCE"],
          deployment_id: ENV["AZURE_OPENAI_DEPLOYMENT_ID"],
          model: ENV.fetch("AZURE_OPENAI_MODEL", "gpt-4")

        def simple_prompt
          prompt(
            messages: [ { role: "user", content: "Say 'test' once." } ],
            max_completion_tokens: 10
          )
        end

        def hello_world
          prompt("Say hello world")
        end
      end

      setup do
        skip "Azure OpenAI credentials not configured" unless has_azure_openai_credentials?
      end

      test "chat completion response has correct structure" do
        VCR.use_cassette("integration/azure/response_test/simple_prompt") do
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

      test "basic hello world prompt works" do
        VCR.use_cassette("integration/azure/response_test/hello_world") do
          response = PromptAgent.hello_world.generate_now

          assert response.success?
          assert_not_nil response.message.content
          assert_includes response.message.content.downcase, "hello"
        end
      end

      test "response includes usage information" do
        VCR.use_cassette("integration/azure/response_test/usage") do
          response = PromptAgent.simple_prompt.generate_now

          assert response.success?
          assert_not_nil response.raw_response
          assert_not_nil response.raw_response[:usage]
          assert_not_nil response.raw_response[:usage][:prompt_tokens]
          assert_not_nil response.raw_response[:usage][:completion_tokens]
        end
      end
    end
  end
end
