require_relative "../_base_provider"
require_relative "chat/request"

module ActiveAgent
  module GenerationProvider
    module OpenAI
      class ChatProvider < BaseProvider
        protected

        # @return response [ActiveAgent::GenerationProvider::Response]
        def resolve_prompt(resolver)
          request = Chat::Request.new      # Default Options
          request.merge!(options.to_hc)    # Agent Options
          request.merge!(resolver.context) # Action Options

          unless resolver.message_stack.empty?
            request.messages = resolver.message_stack # Callback Messages
          end

          # @todo Bubble up Invalid Requests

          ## Prepare Executation Environment
          parameters = request.to_hc
          parameters[:stream] = process_stream(resolver) if request.stream

          resolver.request = request
          resolver.message_stack.replace(parameters[:messages])

          ## Execute
          api_response = client.chat(parameters:)
          process_finished(resolver, api_response.presence&.deep_symbolize_keys)
        end

        # @return void
        def process_stream_chunk(resolver, api_response_chunk)
          return unless api_response_chunk.dig(:choices, 0)

          # If we have a delta, we need to update a message in the stack
          if (api_message = api_response_chunk.dig(:choices, 0))
            message = find_or_create_message(resolver, api_message[:index])
            message = message_merge_delta(message, api_message[:delta])

            # Stream back content changes as they come in
            if api_message.dig(:delta, :content)
              resolver.stream_callback.call(message,  api_message.dig(:delta, :content), false)
            end
          end

          # If this is the last api_response_chunk to be processed
          return unless api_response_chunk.dig(:choices, 0, :finish_reason)

          # Once we are finished, close out and run tooling callbacks (Recursive)
          process_finished(resolver)

          # Then we can close out the stream
          # @todo Debounce the close up.
          resolver.stream_callback.call(resolver.message_stack.last, nil, true)
        end

        # @return void
        def process_tool_calls(resolver, api_tool_calls)
          api_tool_calls.each do |api_tool_call|
            content = case api_tool_call[:type]
            when "function"
              process_tool_call_function(resolver, api_tool_call[:function])
            else
              fail "Unexpected Tool Call Type: #{api_tool_call[:type]}"
            end

            message = Chat::Requests::Messages::Tool.new(tool_call_id: api_tool_call[:id], content: content.to_json)
            resolver.message_stack.push(message.to_hc)
          end
        end

        # @return result [Unknown]
        def process_tool_call_function(resolver, api_function_call)
          name   = api_function_call[:name]
          kwargs = JSON.parse(api_function_call[:arguments], symbolize_names: true) if api_function_call[:arguments]

          resolver.tool_callback.call(name, **kwargs)
        end

        # @return response [ActiveAgent::GenerationProvider::Response]
        def process_finished(resolver, api_response = nil)
          if (api_message = api_response&.dig(:choices, 0, :message))
            resolver.message_stack.push(api_message)
          end

          if (tool_calls = resolver.message_stack.last[:tool_calls])
            process_tool_calls(resolver, tool_calls)
            resolve_prompt(resolver)
          else
            ActiveAgent::GenerationProvider::Response.new(
              prompt: resolver,
              message: resolver.message_stack.last,
              raw_request: resolver.request,
              raw_response: api_response,
            )
          end
        end

        # ActiveAgent::ActionPrompt::Message.new(
        #     generation_id:     api_message[:id] || api_response[:id],
        #     content:           api_message[:content],
        #     role:              api_message[:role].intern,
        #     action_requested:  api_message[:finish_reason] == "tool_calls",
        #     raw_actions:       api_message[:tool_calls] || [],
        #     requested_actions: handle_actions(api_message[:tool_calls]),
        #     content_type:      resolver.context[:output_schema].present? ? "application/json" : "text/plain"
        # )

        # def embeddings_response(response, request_params = nil)
        #   message = ActiveAgent::ActionPrompt::Message.new(content: response.dig("data", 0, "embedding"), role: "assistant")

        #   @response = ActiveAgent::GenerationProvider::Response.new(
        #     prompt: prompt,
        #     message: message,
        #     raw_response: response,
        #     raw_request: request_params
        #   )
        # end

        private

        # @return message [Hash]
        def find_or_create_message(resolver, id)
          message = resolver.message_stack.find { it[:index] == id }
          return message if message

          resolver.message_stack << { index: id }
          resolver.message_stack.last
        end

        # This to handle the poor design of the chat streaming API. They redesigned it for a reason, and it shows.
        def message_merge_delta(message, delta)
          delta.each do |key, value|
            case message[key]
            when Hash
              message[key] = message_merge_delta(message[key], value)
            when Array
              value.each do |delta_item|
                if delta_item.is_a?(Hash) && delta_item[:index]
                  message_item = message[key].find { |it| it[:index] == delta_item[:index] }
                  if message_item
                    message_merge_delta(message_item, delta_item)
                  else
                    message[key] << delta_item
                  end
                else
                  message[key] << delta_item
                end
              end
            when String
              message[key] += value
            else
              message[key] = value
            end
          end

          message
        end
      end
    end
  end
end
