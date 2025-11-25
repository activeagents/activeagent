require_relative "_base"
require_relative "responses/_types"
require_relative "responses/transforms"

module ActiveAgent
  module Providers
    module OpenAI
      # Provider implementation for OpenAI's Responses API
      #
      # Uses the responses endpoint for improved streaming and structured function
      # calling compared to the chat completions endpoint.
      #
      # @see Base
      # @see https://platform.openai.com/docs/api-reference/responses
      class ResponsesProvider < Base
        include ToolChoiceClearing

        # @return [Class]
        def self.options_klass
          Options
        end

        # @return [Responses::RequestType]
        def self.prompt_request_type
          Responses::RequestType.new
        end

        protected

        # @see BaseProvider#prepare_prompt_request
        # @return [Request]
        def prepare_prompt_request
          prepare_prompt_request_tools

          super
        end

        # Extracts function names from Responses API function_call items.
        #
        # @return [Array<String>]
        def extract_used_function_names
          message_stack
            .select { |item| item[:type] == "function_call" }
            .map { |item| item[:name] }
            .compact
        end

        # Returns true if tool_choice == :required.
        #
        # @return [Boolean]
        def tool_choice_forces_required?
          request.tool_choice == :required
        end

        # Returns [true, name] if tool_choice is a ToolChoiceFunction model object.
        #
        # @return [Array<Boolean, String|nil>]
        def tool_choice_forces_specific?
          if request.tool_choice.is_a?(::OpenAI::Models::Responses::ToolChoiceFunction)
            [ true, request.tool_choice.name ]
          else
            [ false, nil ]
          end
        end

        # @return [Object] OpenAI client's responses endpoint
        def api_prompt_executer
          client.responses
        end

        # @see BaseProvider#api_response_normalize
        # @param api_response [OpenAI::Models::Responses::Response]
        # @return [Hash] normalized response hash
        def api_response_normalize(api_response)
          return api_response unless api_response

          Responses::Transforms.gem_to_hash(api_response)
        end

        # Processes streaming response chunks from the Responses API
        #
        # Event types handled:
        # - `:"response.created"`, `:"response.in_progress"` - response lifecycle
        # - `:"response.output_item.added"` - message or function call added
        # - `:"response.content_part.added"` - content part started
        # - `:"response.output_text.delta"` - incremental text updates
        # - `:"response.output_text.done"` - complete text
        # - `:"response.function_call_arguments.delta"` - function argument updates
        # - `:"response.function_call_arguments.done"` - complete function arguments
        # - `:"response.content_part.done"` - content part completed
        # - `:"response.output_item.done"` - message or function call completed
        # - `:"response.completed"` - response finished
        #
        # @param api_response_event [Hash] streaming chunk with :type key
        # @return [void]
        # @see Base#process_stream_chunk
        def process_stream_chunk(api_response_event)
          instrument("stream_chunk.active_agent", chunk_type: api_response_event.type)

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
            message = message_stack.find { _1[:id] == api_response_event.item_id }
            message[:content] += api_response_event.delta
            broadcast_stream_update(message, api_response_event.delta)

          # -> -> -> Content Text Completed [Full Text]
          when :"response.output_text.done"
            message = message_stack.find { _1[:id] == api_response_event.item_id }
            message[:content] = api_response_event.text
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
            raise "Unexpected Response Chunk Type: #{api_response_event.type}"
          end
        end

        # Processes output item added events from streaming response
        #
        # Handles message and function_call item types. For messages, adds to stack
        # with empty content. For function calls, waits for completion event.
        #
        # Required because API returns empty array instead of empty string for
        # initial message content due to serialization bug.
        #
        # @param api_response_event [Hash] response chunk with :item key
        # @return [void]
        def process_stream_output_item_added(api_response_event)
          case api_response_event.item.type
          when :message
            # PATCH: API returns an empty array instead of empty string due to a bug in their serialization
            item_hash = Responses::Transforms.gem_to_hash(api_response_event.item).compact_blank
            message_stack << { content: "" }.merge(item_hash)
          when :function_call
            # No-Op: Wait for FC to Land (-> response.output_item.done)
          else
            raise "Unexpected Item Type: #{api_response_event.item.type}"
          end
        end

        # Processes output item completion events from streaming response
        #
        # For function calls, adds completed item to message stack.
        # For messages, no action needed as content already updated via delta events.
        #
        # @param api_response_event [Hash] response chunk with completed :item
        # @return [void]
        def process_stream_output_item_done(api_response_event)
          case api_response_event.item.type
          when :message
            # No-Op: Message Up to Date
          when :function_call
            item_hash = Responses::Transforms.gem_to_hash(api_response_event.item)
            message_stack << item_hash
          else
            raise "Unexpected Item Type: #{api_response_event.item.type}"
          end
        end

        # Executes function calls and creates output messages for conversation continuation
        #
        # @param api_function_calls [Array<Hash>] function calls with :call_id and :name keys
        # @return [void]
        # @see Base#process_function_calls
        def process_function_calls(api_function_calls)
          api_function_calls.each do |api_function_call|
            output = instrument("tool_call.active_agent", tool_name: api_function_call[:name]) do
              process_tool_call_function(api_function_call).to_json
            end

            # Create native gem input item for function call output
            message = ::OpenAI::Models::Responses::ResponseInputItem::FunctionCallOutput.new(
              call_id: api_function_call[:call_id],
              output:
            )

            # Convert to hash for message_stack
            message_stack.push(Responses::Transforms.gem_to_hash(message))
          end
        end

        # Converts OpenAI gem response object to hash for storage.
        #
        # @param api_response [OpenAI::Models::Responses::Response]
        # @return [Common::PromptResponse, nil]
        def process_prompt_finished(api_response = nil)
          # Convert gem object to hash so that raw_response["usage"] works
          api_response_hash = api_response ? Responses::Transforms.gem_to_hash(api_response) : nil
          super(api_response_hash)
        end

        # Extracts messages from completed API response.
        #
        # @param api_response [Hash] converted response hash
        # @return [Array, nil] output array from response.output or nil
        def process_prompt_finished_extract_messages(api_response)
          return unless api_response

          # Response is already a hash from process_prompt_finished
          api_response[:output]
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
