# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/active_agent/providers/open_ai/responses_provider"

module Providers
  module OpenAI
    module Responses
      class StreamingErrorsTest < ActiveSupport::TestCase
        include WebMock::API

        test "an error event preserves the API error message and code" do
          assert_stream_error({ type: "error", code: "server_error", message: "Please try again", param: nil },
            "server_error: Please try again")
        end

        test "a failed response preserves its nested error" do
          assert_stream_error({ type: "response.failed", response: {
            id: "resp_failed", status: "failed", error: { code: "server_error", message: "Generation failed" }
          } }, "server_error: Generation failed")
        end

        test "a failed response without error details still raises a provider error" do
          assert_stream_error({ type: "response.failed", response: {
            id: "resp_failed", status: "failed", error: nil
          } }, "OpenAI response failed")
        end

        private

        def assert_stream_error(event, message)
          events = [ { type: "response.created", response: {
            id: "resp_failed", status: "in_progress", output: []
          } }, event ]
          body = events.each_with_index.map do |chunk, index|
            "event: #{chunk[:type]}\ndata: #{chunk.merge(sequence_number: index).to_json}\n\n"
          end.join
          stub_request(:post, "https://api.openai.com/v1/responses").to_return(
            status: 200, headers: { "Content-Type" => "text/event-stream" }, body:
          )
          provider = ActiveAgent::Providers::OpenAI::ResponsesProvider.new(
            service: "OpenAI", api_key: "test-key", model: "gpt-5", stream: true,
            messages: [ { role: "user", content: "Hello" } ],
            stream_broadcaster: ->(_message, _delta, _event_type) { }
          )

          error = assert_raises(ActiveAgent::Providers::Errors::ProviderError) { provider.prompt }
          assert_equal message, error.message
        end
      end
    end
  end
end
