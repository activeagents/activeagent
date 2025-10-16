# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../open_ai/chat_api/native_messages_format_test"

module Integration
  module OpenRouter
    class NativeMessagesFormatTest < ActiveSupport::TestCase
      include Integration::TestHelper

      class TestAgent < OpenAI::ChatAPI::NativeMessagesFormatTest::TestAgent
        generate_with :open_router, model: "gpt-5", temperature: nil
      end

      ################################################################################
      # This automatically runs all the tests for these the test actions
      ################################################################################
      [
        :text_input,
        :image_input,
        :streaming,
        :functions,
        :logprobs,
        :web_search,
        :functions_with_streaming
      ].each do |action_name|
        test_request_builder(TestAgent, action_name)
      end
    end
  end
end
