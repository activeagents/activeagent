require_relative "_base"
require_relative "responses/_types"

module ActiveAgent
  module Providers
    module OpenAI
      # Handles OpenAI's Responses API with improved streaming and structured function calling.
      #
      # Uses the newer responses endpoint instead of the chat completions endpoint
      # for more reliable streaming and better structured interactions with function calls.
      #
      # @see Base
      # @see https://platform.openai.com/docs/api-reference/responses
      class ResponsesProvider < Base
        # @return [Class]
        def self.options_klass
          Options
        end

        # @return [Responses::RequestType]
        def self.prompt_request_type
          Responses::RequestType.new
        end

        protected

        # @return [Object] OpenAI client's responses endpoint
        def api_prompt_executer
          client.responses
        end

        # Processes streaming response chunks from the Responses API.
        #
        # Handles event types: response.created, response.output_item.added,
        # response.output_text.delta, response.function_call_arguments.delta,
        # and response.completed. Updates message stack and broadcasts streaming
        # updates to listeners.
        #
        # @param api_response_event [Hash] streaming response chunk with :type key
        # @return [void]
        def process_stream_chunk(api_response_event)
          instrument("stream_chunk_processing.provider.active_agent", chunk_type: api_response_event.type)

          case api_response_event.type
          # Response Created
          when :"response.created", :"response.in_progress"
            broadcast_stream_open

          # -> Message Created
          when :"response.output_item.added"
            process_stream_output_item_added(api_response_event)

          # -> -> Content Part Create
          when :"response.content_part.added"

          # -> -> -> Content Text Append
          when :"response.output_text.delta"
            message = message_stack.find { _1[:id] == api_response_event[:item_id] }
            message[:content] += api_response_event[:delta]
            broadcast_stream_update(message, api_response_event[:delta])

          # -> -> -> Content Text Completed [Full Text]
          when :"response.output_text.done"
            message = message_stack.find { _1[:id] == api_response_event[:item_id] }
            message[:content] = api_response_event[:text]
            broadcast_stream_update(message, nil) # Don't double send content

          # -> -> -> Content Function Call Append
          when :"response.function_call_arguments.delta", :"response.function_call_arguments.done"
          # No-Op: Wait for FC to Land

          # -> -> Content Part Completed [Full Part]
          when :"response.content_part.done"

          # -> Message Completed
          when :"response.output_item.done"
            process_stream_output_item_done(api_response_event)

          # Response Completed
          when :"response.completed"
            # Once we are finished, close out and run tooling callbacks (Recursive)
            process_prompt_finished
          else
            fail "Unexpected Response Chunk Type: #{type}"
          end
        end

        # Processes output item added events from streaming response.
        #
        # @param api_response_event [Hash] response chunk with :item key
        # @return [void]
        def process_stream_output_item_added(api_response_event)
          case api_response_event.item.type
          when :message
            # PATCH: API returns an empty array instead of empty string due to a bug in their serialization
            message_stack << { content: "" }.merge(api_response_event.item.to_h.compact_blank)
          when :function_call
            # No-Op: Wait for FC to Land (-> response.output_item.done)
          else
            fail "Unexpected Item Type: #{api_response_event.item.type}"
          end
        end

        # Processes output item completion events from streaming response.
        #
        # @param api_response_event [Hash] response chunk with completed :item
        # @return [void]
        def process_stream_output_item_done(api_response_event)
          case api_response_event.item.type
          when :message
            # No-Op: Message Up to Date
          when :function_call
            message_stack << api_response_event.item
          else
            fail "Unexpected Item Type: #{api_response_event.item.type}"
          end
        end

        # Executes function calls and creates output messages for conversation continuation.
        #
        # @param api_function_calls [Array<Hash>] function calls with :call_id and :name keys
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

        # Extracts messages from completed API response.
        #
        # @param api_response [Hash] completed API response
        # @return [Array, nil] output array from response[:output] or nil
        def process_prompt_finished_extract_messages(api_response)
          api_response&.dig(:output)
        end

        # Extracts function calls from message stack.
        #
        # @return [Array<Hash>] function call objects with type "function_call"
        def process_prompt_finished_extract_function_calls
          message_stack.select { _1[:type] == "function_call" }
        end
      end
    end
  end
end
