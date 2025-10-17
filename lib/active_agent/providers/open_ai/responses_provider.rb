require_relative "_base_provider"
require_relative "responses/request"

module ActiveAgent
  module Providers
    module OpenAI
      # @see https://platform.openai.com/docs/api-reference/responses
      class ResponsesProvider < BaseProvider
        protected

        def prompt_request_klass = Responses::Request
        def options_klass        = Options

        def api_prompt_execute(parameters)
          client.responses.create(parameters:).presence&.deep_symbolize_keys
        end

        def process_stream_chunk(api_response_chunk)
          api_response_chunk.deep_symbolize_keys!

          case (type = api_response_chunk[:type].to_sym)
          # Response Created
          when :"response.created", :"response.in_progress"
            broadcast_stream_open

          # -> Message Created
          when :"response.output_item.added"
            process_stream_output_item_added(api_response_chunk)

          # -> -> Content Part Create
          when :"response.content_part.added"

          # -> -> -> Content Text Append
          when :"response.output_text.delta"
            message = message_stack.find { it[:id] == api_response_chunk[:item_id] }
            message[:content] += api_response_chunk[:delta]
            broadcast_stream_update(message, api_response_chunk[:delta])

          # -> -> -> Content Text Completed [Full Text]
          when :"response.output_text.done"
            message = message_stack.find { it[:id] == api_response_chunk[:item_id] }
            message[:content] = api_response_chunk[:text]
            broadcast_stream_update(message, api_response_chunk[:text])

          # -> -> -> Content Function Call Append
          when :"response.function_call_arguments.delta", :"response.function_call_arguments.done"
          # No-Op: Wait for FC to Land

          # -> -> Content Part Completed [Full Part]
          when :"response.content_part.done"

          # -> Message Completed
          when :"response.output_item.done"
            process_stream_output_item_done(api_response_chunk)

          # Response Completed
          when :"response.completed"
            # Once we are finished, close out and run tooling callbacks (Recursive)
            process_prompt_finished
          else
            fail "Unexpected Response Chunk Type: #{type}"
          end
        end

        def process_stream_output_item_added(api_response_chunk)
          case (type = api_response_chunk[:item][:type].to_sym)
          when :message
            # PATCH: API returns an empty array instead of empty string due to a bug in their serialization
            message_stack << { content: "" }.merge(api_response_chunk[:item].compact_blank)
          when :function_call
            # No-Op: Wait for FC to Land (-> response.output_item.done)
          else
            fail "Unexpected Item Type: #{type}"
          end
        end

        def process_stream_output_item_done(api_response_chunk)
          case (type = api_response_chunk[:item][:type].to_sym)
          when :message
            # No-Op: Message Up to Date
          when :function_call
            message_stack << api_response_chunk.dig(:item)
          else
            fail "Unexpected Item Type: #{type}"
          end
        end

        # @return void
        def process_function_calls(api_function_calls)
          api_function_calls.each do |api_function_call|
            message = Responses::Requests::Inputs::FunctionCallOutput.new(
              call_id: api_function_call[:call_id],
              output:  process_tool_call_function(api_function_call).to_json
            )

            message_stack.push(message.to_hc)
          end
        end

        def process_prompt_finished_extract_messages(api_response)
          api_response&.dig(:output)
        end

        def process_prompt_finished_extract_function_calls
          message_stack.select { it[:type] == "function_call" }
        end
      end
    end
  end
end
