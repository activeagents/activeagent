# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/active_agent/providers/open_ai/responses_provider"

module Providers
  module OpenAI
    module Responses
      # A streamed answer that used a built-in tool, such as web search, has
      # output items and progress events for the tool call before the message,
      # and annotations on the text that cites it.
      class BuiltInToolsStreamingTest < ActiveSupport::TestCase
        include WebMock::API

        ENDPOINT = "https://api.openai.com/v1/responses"

        class ToolAgent < ApplicationAgent
          generate_with :openai, model: "gpt-4.1", api_key: "test-key"

          def ask(tools:)
            prompt(message: "What colour is grass?", tools:, stream: true)
          end
        end

        MESSAGE = { id: "msg_1", type: "message", role: "assistant", status: "completed",
                    content: [ { type: "output_text", text: "Grass is green.", annotations: [] } ] }.freeze
        ANNOTATION = { type: "url_citation", url: "https://example.com", title: "Example",
                       start_index: 0, end_index: 15 }.freeze
        USAGE = { input_tokens: 10, output_tokens: 5, total_tokens: 15,
                  input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } }.freeze

        SEARCH = { id: "ws_1", type: "web_search_call", status: "completed",
                   action: { type: "search", query: "grass colour" } }.freeze
        FILE_SEARCH = { id: "fs_1", type: "file_search_call", status: "completed",
                        queries: [ "grass colour" ], results: nil }.freeze
        IMAGE = { id: "ig_1", type: "image_generation_call", status: "completed", result: "aW1hZ2U=" }.freeze
        CODE = { id: "ci_1", type: "code_interpreter_call", status: "completed", code: "print('green')",
                 container_id: "cntr_1", outputs: [ { type: "logs", logs: "green" } ] }.freeze
        MCP_TOOLS = { id: "mcpl_1", type: "mcp_list_tools", server_label: "wiki",
                      tools: [ { name: "ask", input_schema: { type: "object", properties: {} } } ] }.freeze
        MCP_CALL = { id: "mcp_1", type: "mcp_call", server_label: "wiki", name: "ask",
                     arguments: "{}", output: "Grass is green." }.freeze

        # Progress events of one tool call, as the API streams them between the
        # item's output_item.added and output_item.done.
        def progress_events(item, output_index)
          ids = { item_id: item[:id], output_index: }

          case item[:type]
          when "web_search_call"
            %w[in_progress searching completed].map { { type: "response.web_search_call.#{_1}", **ids } }
          when "file_search_call"
            %w[in_progress searching completed].map { { type: "response.file_search_call.#{_1}", **ids } }
          when "image_generation_call"
            [ { type: "response.image_generation_call.in_progress", **ids },
              { type: "response.image_generation_call.generating", **ids },
              { type: "response.image_generation_call.partial_image", **ids, partial_image_index: 0, partial_image_b64: "aW0=" },
              { type: "response.image_generation_call.completed", **ids } ]
          when "code_interpreter_call"
            [ { type: "response.code_interpreter_call.in_progress", **ids },
              { type: "response.code_interpreter_call_code.delta", **ids, delta: item[:code] },
              { type: "response.code_interpreter_call_code.done", **ids, code: item[:code] },
              { type: "response.code_interpreter_call.interpreting", **ids },
              { type: "response.code_interpreter_call.completed", **ids } ]
          when "mcp_list_tools"
            %w[in_progress completed].map { { type: "response.mcp_list_tools.#{_1}", **ids } }
          when "mcp_call"
            [ { type: "response.mcp_call_arguments.delta", **ids, delta: item[:arguments] },
              { type: "response.mcp_call_arguments.done", **ids, arguments: item[:arguments] },
              { type: "response.mcp_call.in_progress", **ids },
              { type: "response.mcp_call.completed", **ids } ]
          end
        end

        def sse_body(*tool_items)
          response = { id: "resp_1", object: "response", created_at: 1_761_502_994, model: "gpt-4.1",
                       parallel_tool_calls: true, tool_choice: "auto", tools: [] }
          shell = response.merge(status: "in_progress", output: [])
          message_ids = { item_id: "msg_1", output_index: tool_items.size, content_index: 0 }
          part = { type: "output_text", text: "", annotations: [] }

          events = [
            { type: "response.created", response: shell },
            { type: "response.in_progress", response: shell }
          ]
          tool_items.each_with_index do |item, output_index|
            events << { type: "response.output_item.added", output_index:, item: item.merge(status: "in_progress") }
            events.concat(progress_events(item, output_index))
            events << { type: "response.output_item.done", output_index:, item: }
          end
          events.concat([
            { type: "response.output_item.added", output_index: tool_items.size, item: MESSAGE.merge(status: "in_progress", content: []) },
            { type: "response.content_part.added", **message_ids, part: },
            { type: "response.output_text.delta", **message_ids, delta: "Grass is green.", logprobs: [] },
            { type: "response.output_text.annotation.added", **message_ids, annotation_index: 0, annotation: ANNOTATION },
            { type: "response.output_text.done", **message_ids, text: "Grass is green.", logprobs: [] },
            { type: "response.content_part.done", **message_ids, part: part.merge(text: "Grass is green.") },
            { type: "response.output_item.done", output_index: tool_items.size, item: MESSAGE },
            { type: "response.completed", response: response.merge(status: "completed", output: [ *tool_items, MESSAGE ], usage: USAGE) }
          ])
          events.each_with_index.map { |event, index| "event: #{event[:type]}\ndata: #{event.merge(sequence_number: index).to_json}\n\n" }.join
        end

        def assert_completes(tools, *tool_items)
          stub_request(:post, ENDPOINT)
            .to_return(status: 200, headers: { "Content-Type" => "text/event-stream" }, body: sse_body(*tool_items))

          response = ToolAgent.ask(tools:).generate_now

          assert_equal "Grass is green.", response.message.content
        end

        test "a streamed answer that used web search completes" do
          assert_completes([ { type: "web_search_preview" } ], SEARCH)
        end

        test "a streamed answer that used file search completes" do
          assert_completes([ { type: "file_search", vector_store_ids: [ "vs_1" ] } ], FILE_SEARCH)
        end

        test "a streamed answer that generated an image completes" do
          assert_completes([ { type: "image_generation" } ], IMAGE)
        end

        test "a streamed answer that ran the code interpreter completes" do
          assert_completes([ { type: "code_interpreter", container: { type: "auto" } } ], CODE)
        end

        test "a streamed answer that called a remote MCP server completes" do
          assert_completes([ { type: "mcp", server_label: "wiki", server_url: "https://example.com/mcp", require_approval: "never" } ],
                           MCP_TOOLS, MCP_CALL)
        end
      end
    end
  end
end
