# frozen_string_literal: true

require "test_helper"

module Overview
  # Tests for the Overview::SupportAgent example used in documentation.
  #
  # This test file provides code examples for the overview.md documentation.
  # All examples are imported into docs using VitePress imports.
  class SupportAgentTest < ActiveSupport::TestCase
    test "overview example" do
      VCR.use_cassette("overview/support_agent") do
        # region overview_example
        response = SupportAgent.with(question: "How do I reset my password?").help.generate_now
        puts response.message.content
        # endregion overview_example

        doc_example_output(response)

        assert response.success?
        assert_not_nil response.message.content
        assert response.message.content.length > 0
      end
    end
  end
end
