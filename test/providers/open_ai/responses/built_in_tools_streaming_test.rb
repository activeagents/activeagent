# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/active_agent/providers/open_ai/responses_provider"

module Providers
  module OpenAI
    module Responses
      # A streamed answer that used a built-in tool, such as web search, has an
      # output item and progress events for the tool call, and annotations on
      # the text that cites it.
      class BuiltInToolsStreamingTest < ActiveSupport::TestCase
        include WebMock::API

        ENDPOINT = "https://api.openai.com/v1/responses"

        class SearchAgent < ApplicationAgent
          generate_with :openai, model: "gpt-4.1", api_key: "test-key"

          def search
            prompt(message: "What colour is grass?", tools: [ { type: "web_search_preview" } ], stream: true)
          end
        end

        SEARCH = { id: "ws_1", type: "web_search_call", status: "completed",
                   action: { type: "search", query: "grass colour" } }.freeze
        MESSAGE = { id: "msg_1", type: "message", role: "assistant", status: "completed",
                    content: [ { type: "output_text", text: "Grass is green.", annotations: [] } ] }.freeze
        ANNOTATION = { type: "url_citation", url: "https://example.com", title: "Example",
                       start_index: 0, end_index: 15 }.freeze
        USAGE = { input_tokens: 10, output_tokens: 5, total_tokens: 15,
                  input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } }.freeze

        def sse_body
          response = { id: "resp_1", object: "response", created_at: 1_761_502_994, model: "gpt-4.1",
                       parallel_tool_calls: true, tool_choice: "auto", tools: [] }
          shell = response.merge(status: "in_progress", output: [])
          search_ids = { item_id: "ws_1", output_index: 0 }
          message_ids = { item_id: "msg_1", output_index: 1, content_index: 0 }
          part = { type: "output_text", text: "", annotations: [] }

          events = [
            { type: "response.created", response: shell },
            { type: "response.in_progress", response: shell },
            { type: "response.output_item.added", output_index: 0, item: SEARCH.merge(status: "in_progress") },
            { type: "response.web_search_call.in_progress", **search_ids },
            { type: "response.web_search_call.searching", **search_ids },
            { type: "response.web_search_call.completed", **search_ids },
            { type: "response.output_item.done", output_index: 0, item: SEARCH },
            { type: "response.output_item.added", output_index: 1, item: MESSAGE.merge(status: "in_progress", content: []) },
            { type: "response.content_part.added", **message_ids, part: },
            { type: "response.output_text.delta", **message_ids, delta: "Grass is green.", logprobs: [] },
            { type: "response.output_text.annotation.added", **message_ids, annotation_index: 0, annotation: ANNOTATION },
            { type: "response.output_text.done", **message_ids, text: "Grass is green.", logprobs: [] },
            { type: "response.content_part.done", **message_ids, part: part.merge(text: "Grass is green.") },
            { type: "response.output_item.done", output_index: 1, item: MESSAGE },
            { type: "response.completed", response: response.merge(status: "completed", output: [ SEARCH, MESSAGE ], usage: USAGE) }
          ]
          events.each_with_index.map { |event, index| "event: #{event[:type]}\ndata: #{event.merge(sequence_number: index).to_json}\n\n" }.join
        end

        test "a streamed answer that used web search completes" do
          stub_request(:post, ENDPOINT)
            .to_return(status: 200, headers: { "Content-Type" => "text/event-stream" }, body: sse_body)

          response = SearchAgent.search.generate_now

          assert_equal "Grass is green.", response.message.content
        end
      end
    end
  end
end
