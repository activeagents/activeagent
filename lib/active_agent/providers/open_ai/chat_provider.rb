require_relative "_base"
require_relative "chat/_types"

module ActiveAgent
  module Providers
    module OpenAI
      # Provider implementation for OpenAI's Chat Completions API
      #
      # Handles chat-based interactions including streaming responses,
      # function/tool calling, and message management.
      #
      # @see Base
      # @see https://platform.openai.com/docs/api-reference/chat
      class ChatProvider < Base
        include ToolChoiceClearing

        # @return [Class] the options class for this provider
        def self.options_klass
          Options
        end

        # @return [Chat::RequestType] request type instance for chat completions
        def self.prompt_request_type
          Chat::RequestType.new
        end

        protected

        # Chat Completions reports a streamed request's token usage on a final
        # chunk, and only when the request opts in.
        #
        # @return [Hash]
        # @see Base#api_stream_usage_parameters
        def api_stream_usage_parameters
          { stream_options: { include_usage: true } }
        end

        # @return [OpenAI::Client::Completions] the API client for chat completions
        # @see Base#api_prompt_executer
        def api_prompt_executer
          client.chat.completions
        end

        # @see BaseProvider#prepare_prompt_request
        # @return [Request]
        def prepare_prompt_request
          prepare_prompt_request_tools
          super
        end

        # Extracts function names from Chat API tool_calls in assistant messages.
        #
        # @return [Array<String>]
        def extract_used_function_names
          message_stack
            .select { |msg| msg[:role] == "assistant" && msg[:tool_calls] }
            .flat_map { |msg| msg[:tool_calls] }
            .map { |tc| tc.dig(:function, :name) }
            .compact
        end

        # Returns true if tool_choice == "required".
        #
        # @return [Boolean]
        def tool_choice_forces_required?
          request.tool_choice == "required"
        end

        # Returns [true, name] if tool_choice is a hash with nested function name.
        #
        # @return [Array<Boolean, String|nil>]
        def tool_choice_forces_specific?
          if request.tool_choice.is_a?(Hash)
            [ true, request.tool_choice.dig(:function, :name) ]
          else
            [ false, nil ]
          end
        end

        # @see BaseProvider#api_response_normalize
        # @param api_response [OpenAI::Models::ChatCompletion]
        # @return [Hash] normalized response hash
        def api_response_normalize(api_response)
          return api_response unless api_response

          Chat::Transforms.gem_to_hash(api_response)
        end

        # Processes streaming response chunks from OpenAI's chat API
        #
        # Handles message deltas, content updates, and completion detection.
        # Manages the message stack and broadcasts streaming updates.
        #
        # Event types handled:
        # - `:chunk` - message content and tool call deltas
        # - `:"content.delta"` - incremental content updates
        # - `:"content.done"` - complete content delivery
        # - `:"tool_calls.function.arguments.delta"` - tool argument deltas
        # - `:"tool_calls.function.arguments.done"` - complete tool arguments
        #
        # @param api_response_event [OpenAI::Helpers::Streaming::ChatChunkEvent]
        # @return [void]
        # @see Base#process_stream_chunk
        def process_stream_chunk(api_response_event)
          instrument("stream_chunk.active_agent")

          broadcast_stream_open

          # Called Multiple Times: [Chunk<T>, T]<Content, ToolsCall>
          case api_response_event.type
          when :chunk
            # The usage chunk carries usage and an empty choices array, so it
            # must be read before choices.first is dereferenced below.
            record_stream_usage(api_response_event.chunk.try(:usage))

            api_message = api_response_event.chunk.choices.first
            return if api_message.nil?

            # If we have a delta, we need to update a message in the stack
            message = find_or_create_message(api_message.index)
            message_merge_delta(message, api_message.delta.deep_to_h)

            # Stream back content changes as they come in
            if api_message.delta.content
              broadcast_stream_update(message_stack.last, api_message.delta.content)
            end
          when :"content.delta"
            # Returns the deltas, without context
            # => {type: :"content.delta", delta: "", snapshot: "", parsed: nil}
            # => {type: :"content.delta", delta: "Hi", snapshot: "Hi", parsed: nil}
          when :"content.done"
            # Returns the full content when complete
            # => {type: :"content.done", content: "Hi there! How can I help you today?", parsed: nil}

            # Close out and run tooling callbacks (Recursive) — but not here.
            # The usage chunk is emitted *after* content.done, and finishing
            # at this point builds the response from a usage_stack that has
            # not received it yet, so a streamed generation reports zero
            # tokens. Deferred to stream_finished!, which the base provider
            # calls once the stream has drained.
            self.stream_completion_pending = true
          when :"tool_calls.function.arguments.delta"
            # => {type: :"tool_calls.function.arguments.delta", name: "get_current_weather", index: 0, arguments: "", parsed: nil, arguments_delta: ""}
          when :"tool_calls.function.arguments.done"
            # => => {type: :"tool_calls.function.arguments.done", index: 0, name: "get_current_weather", arguments: "{\"location\":\"Boston, MA\"}", parsed: nil}
          when :"refusal.delta"
            # No-Op; the refusal is merged into the message from the :chunk event
          when :"refusal.done"
            # A refused message ends here, with no content.done
            self.stream_completion_pending = true
          when :"logprobs.content.delta", :"logprobs.content.done", :"logprobs.refusal.delta", :"logprobs.refusal.done"
            # No-Op; sent when the request asks for logprobs
          else
            fail "Unexpected Response Event Type: #{api_response_event.type}"
          end
        end

        # Processes function/tool calls from the API response
        #
        # Executes each tool call and creates tool response messages
        # for the next iteration of the conversation. Pushes nothing when a
        # tool asked the user for input.
        #
        # @param api_function_calls [Array<Hash>] function calls with :type, :id, and :function keys
        # @return [void]
        # @see Base#process_function_calls
        def process_function_calls(api_function_calls)
          results = dispatch_tool_calls(api_function_calls) do |api_function_call|
            instrument("tool_call.active_agent", tool_name: api_function_call.dig(:function, :name)) do
              case api_function_call[:type].to_s
              when "function"
                process_tool_call_function(api_function_call[:function])
              else
                fail "Unexpected Tool Call Type: #{api_function_call[:type]}"
              end
            end
          end

          return unless results

          api_function_calls.zip(results).each do |api_function_call, content|
            # Create tool message using gem's message param class
            message = ::OpenAI::Models::Chat::ChatCompletionToolMessageParam.new(
              role: "tool",
              tool_call_id: api_function_call[:id],
              content: content.to_json
            )

            # Serialize and push to message stack
            message_hash = Chat::Transforms.gem_to_hash(message)
            message_stack.push(message_hash)
          end
        end

        # Extracts messages from the completed API response.
        # Converts OpenAI gem response object to hash for storage.
        #
        # @param api_response [OpenAI::Models::Chat::ChatCompletion]
        # @return [Common::PromptResponse, nil]
        def process_prompt_finished(api_response = nil)
          # Convert gem object to hash so that raw_response["usage"] works
          api_response_hash = api_response ? Chat::Transforms.gem_to_hash(api_response) : nil
          super(api_response_hash)
        end

        # Extracts messages from completed API response.
        #
        # @param api_response [Hash] converted response hash
        # @return [Array<Hash>, nil] single-element array with message or nil if no message
        # @see Base#process_prompt_finished_extract_messages
        def process_prompt_finished_extract_messages(api_response)
          return unless api_response

          api_message = api_response[:choices][0][:message]

          [ api_message ]
        end

        # @see InputRequests#tool_call_reference
        # @param api_function_call [Hash]
        # @return [Array(String, String)]
        def tool_call_reference(api_function_call)
          [ api_function_call[:id].to_s, api_function_call.dig(:function, :name).to_s ]
        end

        # @see InputRequests#tool_call_arguments
        # @param api_function_call [Hash]
        # @return [Hash, String, nil]
        def tool_call_arguments(api_function_call)
          parse_tool_call_arguments(api_function_call.dig(:function, :arguments))
        end

        # Extracts function calls from the last message in the stack.
        #
        # @return [Array<Hash>, nil] tool call objects or nil if no tool calls
        # @see Base#process_prompt_finished_extract_function_calls
        def process_prompt_finished_extract_function_calls
          message_stack.last[:tool_calls]
        end

        # Merges streaming delta into a message
        #
        # Separated from hash_merge_delta to allow Ollama to override role handling.
        #
        # @param message [Hash]
        # @param delta [Hash]
        # @return [Hash] merged message
        def message_merge_delta(message, delta)
          hash_merge_delta(message, delta)
        end

        private

        # Finds an existing message by index or creates a new one
        #
        # @param id [Integer]
        # @return [Hash] found or newly created message
        def find_or_create_message(id)
          message = message_stack.find { _1[:index] == id }
          return message if message

          message_stack << { index: id }
          message_stack.last
        end

        # Finds the streamed tool call an unindexed delta continues
        #
        # OpenAI-compatible servers (Gemini's compatibility endpoint, some Ollama
        # and OpenRouter backends) omit the `index` that ties argument fragments
        # to their call. A delta carrying an `id` continues the call with that
        # id; one without an id or a function name continues the last call;
        # anything else starts a new call.
        #
        # @param tool_calls [Array<Hash>] calls accumulated so far
        # @param delta_item [Hash] unindexed tool call delta
        # @return [Hash, nil] the call to merge into, or nil for a new call
        def unindexed_tool_call_target(tool_calls, delta_item)
          if delta_item[:id].present?
            tool_calls.find { _1[:id] == delta_item[:id] }
          elsif delta_item.dig(:function, :name).blank?
            tool_calls.last
          end
        end

        # Strips the fields a server repeats on every fragment (`id`, `type`,
        # the function name), so merging does not concatenate them.
        #
        # @param hash_item [Hash] the call the fragment continues
        # @param delta_item [Hash] unindexed tool call delta
        # @return [Hash] the fragment to merge
        def unindexed_tool_call_fragment(hash_item, delta_item)
          fragment = delta_item.except(:id, :type)
          if fragment[:function].is_a?(Hash) && fragment.dig(:function, :name) == hash_item.dig(:function, :name)
            fragment = fragment.merge(function: fragment[:function].except(:name))
          end
          fragment
        end

        # Recursively merges delta changes into a hash structure
        #
        # Handles complex delta merging for OpenAI's streaming API, including
        # arrays with indexed items and string concatenation.
        #
        # @param hash [Hash] target hash to merge into
        # @param delta [Hash] delta changes to apply
        # @return [Hash] merged hash
        def hash_merge_delta(hash, delta)
          delta.each do |key, value|
            case hash[key]
            when Hash
              hash[key] = hash_merge_delta(hash[key], value)
            when Array
              value.each do |delta_item|
                if delta_item.is_a?(Hash) && delta_item[:index]
                  hash_item = hash[key].find { _1[:index] == delta_item[:index] }
                  if hash_item
                    hash_merge_delta(hash_item, delta_item)
                  else
                    hash[key] << delta_item
                  end
                elsif key == :tool_calls && delta_item.is_a?(Hash) && (hash_item = unindexed_tool_call_target(hash[key], delta_item))
                  hash_merge_delta(hash_item, unindexed_tool_call_fragment(hash_item, delta_item))
                else
                  hash[key] << delta_item
                end
              end
            when String
              hash[key] += value.to_s
            else
              hash[key] = value
            end
          end

          hash
        end
      end
    end
  end
end
