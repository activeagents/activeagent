require_relative "_base"
require_relative "responses/_types"

module ActiveAgent
  module Providers
    module OpenAI
      # Provider implementation for OpenAI's Responses API.
      #
      # Handles the newer Responses API with improved streaming support
      # and structured function calling. Uses OpenAI's responses endpoint
      # for more reliable and structured interactions.
      #
      # @see Base
      # @see https://platform.openai.com/docs/api-reference/responses
      class ResponsesProvider < Base
        def options_klass       = Options
        def prompt_request_type = Responses::RequestType.new

        protected

        # Executes a responses request via OpenAI's Responses API.
        #
        # @param parameters [Hash] The responses request parameters
        # @return [Hash, nil] The symbolized API response or nil if empty
        def api_prompt_execute(parameters)
          instrument("api_request.provider.active_agent", model: parameters[:model])
          client.responses.create(parameters:).presence&.deep_symbolize_keys
        end

        # Processes streaming response chunks from OpenAI's Responses API.
        #
        # Handles various response event types including response creation,
        # output items, content parts, and function calls. Manages the message
        # stack and broadcasts streaming updates.
        #
        # @param api_response_chunk [Hash] The streaming response chunk
        # @return [void]
        def process_stream_chunk(api_response_chunk)
          api_response_chunk.deep_symbolize_keys!

          type = api_response_chunk[:type].to_sym
          instrument("stream_chunk_processing.provider.active_agent", chunk_type: type)

          case type
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

        # Processes output item added events from the streaming response.
        #
        # @param api_response_chunk [Hash] The response chunk containing the added item
        # @return [void]
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

        # Processes output item completion events from the streaming response.
        #
        # @param api_response_chunk [Hash] The response chunk containing the completed item
        # @return [void]
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

        # Processes function/tool calls from the API response.
        #
        # Executes each function call and creates function call output messages
        # for the next iteration of the conversation.
        #
        # @param api_function_calls [Array<Hash>] Array of function call objects
        # @return [void]
        def process_function_calls(api_function_calls)
          api_function_calls.each do |api_function_call|
            instrument("tool_execution.provider.active_agent", tool_name: api_function_call[:name])

            message = Responses::Requests::Inputs::FunctionCallOutput.new(
              call_id: api_function_call[:call_id],
              output:  process_tool_call_function(api_function_call).to_json
            )

            message_stack.push(message.serialize)
          end
        end

        # Extracts messages from the completed API response.
        #
        # @param api_response [Hash] The completed API response
        # @return [Array, nil] The output array from the response or nil
        def process_prompt_finished_extract_messages(api_response)
          api_response&.dig(:output)
        end

        # Extracts function calls from the message stack.
        #
        # @return [Array<Hash>] Array of function call objects with type "function_call"
        def process_prompt_finished_extract_function_calls
          message_stack.select { it[:type] == "function_call" }
        end
      end
    end
  end
end
