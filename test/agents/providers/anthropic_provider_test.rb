# frozen_string_literal: true

require "test_helper"

module Providers
  class AnthropicProviderTest < ActiveSupport::TestCase
    test "basic generation with Anthropic Claude" do
      VCR.use_cassette("providers/anthropic_basic_generation") do
        # region anthropic_basic_example
        response = AnthropicAgent.with(
          message: "What is the Model Context Protocol?"
        ).ask.generate_now
        # endregion anthropic_basic_example

        doc_example_output(response)

        assert response.success?
        assert_not_nil response.message.content
        assert response.message.content.length > 0
      end
    end
  end
end
