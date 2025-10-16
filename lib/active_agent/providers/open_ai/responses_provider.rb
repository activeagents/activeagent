require_relative "_base_provider"
require_relative "responses/request"

module ActiveAgent
  module Providers
    module OpenAI
      # @see https://platform.openai.com/docs/api-reference/responses
      class ResponsesProvider < BaseProvider
        def initialize(...)
          super

          self.request = Responses::Request.new(context)
        end

        protected

        def client_request_create(parameters:)
          client.responses.create(parameters:)
        end

        def process_stream_chunk(api_response_chunk)
          case api_response_chunk[:type]
          # Response Created
          when "response.created", "response.in_progress"

          # -> Message Created
          when "response.output_item.added"
            process_stream_output_item_added(api_response_chunk)

          # -> -> Content Part Create
          when "response.content_part.added"

          # -> -> -> Content Text Append
          when "response.output_text.delta"
            message = message_stack.find { it[:id] == api_response_chunk[:item_id] }
            message[:content] += api_response_chunk[:delta]
            stream_callback.call(message, api_response_chunk[:delta], false)

          # -> -> -> Content Text Completed [Full Text]
          when "response.output_text.done"
            message = message_stack.find { it[:id] == api_response_chunk[:item_id] }
            message[:content] = api_response_chunk[:text]
            stream_callback.call(message, api_response_chunk[:text], false)

          # -> -> -> Content Function Call Append
          when "response.function_call_arguments.delta", "response.function_call_arguments.done"
          # No-Op: Wait for FC to Land

          # -> -> Content Part Completed [Full Part]
          when "response.content_part.done"

          # -> Message Completed
          when "response.output_item.done"
            process_stream_output_item_done(api_response_chunk)

          # Response Completed
          when "response.completed"
            # Once we are finished, close out and run tooling callbacks (Recursive)
            process_finished

            # Then we can close out the stream
            return if stream_finished
            self.stream_finished = true
            stream_callback.call(message_stack.last, nil, true)
          end
        end

        def process_stream_output_item_added(api_response_chunk)
          case api_response_chunk.dig(:item, :type)
          when "message"
            # PATCH: API returns an empty array instead of empty string due to a bug in their serialization
            message_stack << { content: "" }.merge(api_response_chunk[:item].compact_blank)
          when "function_call"
            # No-Op: Wait for FC to Land (-> response.output_item.done)
          else
            fail "Unexpected Item Type: #{type}"
          end
        end

        def process_stream_output_item_done(api_response_chunk)
          case api_response_chunk.dig(:item, :type)
          when "message"
            # No-Op: Message Up to Date
          when "function_call"
            message_stack << api_response_chunk.dig(:item)
          else
            fail "Unexpected Item Type: #{type}"
          end
        end

        # @return void
        def process_tool_calls(api_tool_calls)
          api_tool_calls.each do |api_tool_call|
            message = Responses::Requests::Inputs::FunctionCallOutput.new(
              call_id: api_tool_call[:call_id],
              output:  process_tool_call_function(api_tool_call).to_json
            )

            message_stack.push(message.to_hc)
          end
        end

        # @return response [ActiveAgent::Providers::Response]
        def process_finished(api_response = nil)
          if (api_messages = api_response&.dig(:output))
            message_stack.push(*api_messages)
          end

          if (tool_calls = message_stack.select { it[:type] == "function_call" }).any?
            process_tool_calls(tool_calls)
            resolve_prompt
          else
            ActiveAgent::Providers::Response.new(
              prompt: context,
              message: message_stack.last,
              raw_request: request,
              raw_response: api_response
            )
          end
        end
      end
    end
  end
end
