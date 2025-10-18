require_relative "../_base_provider"
require_relative "chat/request"

module ActiveAgent
  module Providers
    module OpenAI
      # Provider implementation for OpenAI's Chat Completion API.
      #
      # Handles chat-based interactions including streaming responses,
      # function/tool calling, and message management. Uses OpenAI's
      # chat completions endpoint for generating responses.
      #
      # @see BaseProvider
      # @see https://platform.openai.com/docs/api-reference/chat
      class ChatProvider < BaseProvider
        def options_klass        = Options
        def prompt_request_klass = Chat::Request

        protected

        # Executes a chat completion request via OpenAI's API.
        #
        # @param parameters [Hash] The chat completion request parameters
        # @return [Hash, nil] The symbolized API response or nil if empty
        def api_prompt_execute(parameters)
          client.chat(parameters:).presence&.deep_symbolize_keys
        end

        # Processes streaming response chunks from OpenAI's chat API.
        #
        # Handles message deltas, content updates, and completion detection.
        # Manages the message stack and broadcasts streaming updates.
        #
        # @param api_response_chunk [Hash] The streaming response chunk
        # @return [void]
        def process_stream_chunk(api_response_chunk)
          api_response_chunk.deep_symbolize_keys!

          broadcast_stream_open
          return unless api_response_chunk.dig(:choices, 0)

          # If we have a delta, we need to update a message in the stack
          if (api_message = api_response_chunk.dig(:choices, 0))
            message = find_or_create_message(api_message[:index])
            message = message_merge_delta(message, api_message[:delta])

            # Stream back content changes as they come in
            if api_message.dig(:delta, :content)
              broadcast_stream_update(message_stack.last, api_message.dig(:delta, :content))
            end
          end

          # If this is the last api_response_chunk to be processed
          return unless api_response_chunk.dig(:choices, 0, :finish_reason)

          # Once we are finished, close out and run tooling callbacks (Recursive)
          process_prompt_finished
        end

        # Processes function/tool calls from the API response.
        #
        # Executes each tool call and creates tool response messages
        # for the next iteration of the conversation.
        #
        # @param api_function_calls [Array<Hash>] Array of function call objects
        # @return [void]
        def process_function_calls(api_function_calls)
          api_function_calls.each do |api_function_call|
            content = case api_function_call[:type]
            when "function"
              process_tool_call_function(api_function_call[:function])
            else
              fail "Unexpected Tool Call Type: #{api_function_call[:type]}"
            end

            message = Chat::Requests::Messages::Tool.new(
              tool_call_id: api_function_call[:id],
              content: content.to_json
            )

            message_stack.push(message.to_hc)
          end
        end

        # Extracts messages from the completed API response.
        #
        # @param api_response [Hash] The completed API response
        # @return [Array<Hash>, nil] Array containing the message hash or nil
        def process_prompt_finished_extract_messages(api_response)
          api_message = api_response&.dig(:choices, 0, :message)

          [ api_message ] if api_message
        end

        # Extracts function calls from the last message in the stack.
        #
        # @return [Array<Hash>, nil] Array of tool call hashes or nil
        def process_prompt_finished_extract_function_calls
          message_stack.last[:tool_calls]
        end

        # Merges streaming delta into a message.
        #
        # Separated from hash_merge_delta to allow Ollama to override role handling.
        #
        # @param message [Hash] The current message being built
        # @param delta [Hash] The delta to merge into the message
        # @return [Hash] The merged message
        def message_merge_delta(message, delta)
          hash_merge_delta(message, delta)
        end

        private

        # Finds an existing message by ID or creates a new one.
        #
        # @param id [Integer] The message index ID
        # @return [Hash] The found or newly created message
        def find_or_create_message(id)
          message = message_stack.find { it[:index] == id }
          return message if message

          message_stack << { index: id }
          message_stack.last
        end

        # Recursively merges delta changes into a hash structure.
        #
        # Handles the complex delta merging needed for OpenAI's streaming API,
        # including arrays with indexed items and string concatenation.
        #
        # @param hash [Hash] The target hash to merge into
        # @param delta [Hash] The delta changes to apply
        # @return [Hash] The merged hash
        def hash_merge_delta(hash, delta)
          delta.each do |key, value|
            case hash[key]
            when Hash
              hash[key] = hash_merge_delta(hash[key], value)
            when Array
              value.each do |delta_item|
                if delta_item.is_a?(Hash) && delta_item[:index]
                  hash_item = hash[key].find { |it| it[:index] == delta_item[:index] }
                  if hash_item
                    hash_merge_delta(hash_item, delta_item)
                  else
                    hash[key] << delta_item
                  end
                else
                  hash[key] << delta_item
                end
              end
            when String
              hash[key] += value
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
