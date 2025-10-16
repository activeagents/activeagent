require_relative "../_base_provider"
require_relative "chat/request"

module ActiveAgent
  module Providers
    module OpenAI
      class ChatProvider < BaseProvider
        protected

        def request_klass = Chat::Request
        def options_klass = Options

        def client_request_create(parameters:)
          client.chat(parameters:)
        end

        # @return void
        def process_stream_chunk(api_response_chunk)
          return unless api_response_chunk.dig(:choices, 0)

          # If we have a delta, we need to update a message in the stack
          if (api_message = api_response_chunk.dig(:choices, 0))
            message = find_or_create_message(api_message[:index])
            message = message_merge_delta(message, api_message[:delta])

            # Stream back content changes as they come in
            if api_message.dig(:delta, :content)
              stream_callback.call(message,  api_message.dig(:delta, :content), false)
            end
          end

          # If this is the last api_response_chunk to be processed
          return unless api_response_chunk.dig(:choices, 0, :finish_reason)

          # Once we are finished, close out and run tooling callbacks (Recursive)
          process_finished

          # Then we can close out the stream
          return if stream_finished
          self.stream_finished = true
          stream_callback.call(message_stack.last, nil, true)
        end

        # @return void
        def process_tool_calls(api_tool_calls)
          api_tool_calls.each do |api_tool_call|
            content = case api_tool_call[:type]
            when "function"
              process_tool_call_function(api_tool_call[:function])
            else
              fail "Unexpected Tool Call Type: #{api_tool_call[:type]}"
            end

            message = Chat::Requests::Messages::Tool.new(
              tool_call_id: api_tool_call[:id],
              content: content.to_json
            )

            message_stack.push(message.to_hc)
          end
        end

        # @return response [ActiveAgent::Providers::Response]
        def process_finished(api_response = nil)
          if (api_message = api_response&.dig(:choices, 0, :message))
            message_stack.push(api_message)
          end

          if (tool_calls = message_stack.last[:tool_calls])
            process_tool_calls(tool_calls)
            resolve_prompt
          else
            ActiveAgent::Providers::Response.new(
              prompt: context,
              message: message_stack.last,
              raw_request: request,
              raw_response: api_response,
            )
          end
        end

        # def embeddings_response(response, request_params = nil)
        #   message = ActiveAgent::ActionPrompt::Message.new(content: response.dig("data", 0, "embedding"), role: "assistant")

        #   @response = ActiveAgent::Providers::Response.new(
        #     prompt: prompt,
        #     message: message,
        #     raw_response: response,
        #     raw_request: request_params
        #   )
        # end

        # NOTE: This is seperated from hash_merge_delta to allow Ollama to patch the role resolving
        def message_merge_delta(message, delta)
          hash_merge_delta(message, delta)
        end

        private

        # @return message [Hash]
        def find_or_create_message(id)
          message = message_stack.find { it[:index] == id }
          return message if message

          message_stack << { index: id }
          message_stack.last
        end

        # This to handle the poor design of the chat streaming API. They redesigned it for a reason, and it shows.
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
