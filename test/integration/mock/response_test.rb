# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../../lib/active_agent/providers/mock_provider"

module Integration
  module Mock
    class ResponseTest < ActiveSupport::TestCase
      include Integration::TestHelper

      test "prompt response has correct structure" do
        response = ActiveAgent::Providers::MockProvider.new(
          service: "Mock",
          messages: [ { role: "user", content: "Hello world" } ]
        ).prompt

        # Validate response structure
        assert_instance_of ActiveAgent::Providers::Common::Responses::Prompt, response
        assert response.success?

        # Validate messages array contains Common::Messages objects
        assert_operator response.messages.length, :>, 0
        assert_instance_of ActiveAgent::Providers::Common::Messages::Assistant, response.message

        # Validate message content is pig latin
        assert_match(/ay/, response.message.content)
      end

      test "embed response has correct structure" do
        response = ActiveAgent::Providers::MockProvider.new(
          service: "Mock",
          input: "Hello world"
        ).embed

        # Validate response structure
        assert_instance_of ActiveAgent::Providers::Common::Responses::Embed, response
        assert response.success?

        # Validate data contains mock embedding objects (hash format from provider)
        assert_operator response.data.length, :>, 0
        assert_instance_of Hash, response.data.first
        assert_equal "embedding", response.data.first[:object]
        assert_instance_of Array, response.data.first[:embedding]
        assert_operator response.data.first[:embedding].length, :>, 0
      end
    end
  end
end
