require_relative "../_base_provider"
require_relative "chat/request"

module ActiveAgent
  module GenerationProvider
    module OpenAI
      class ChatProvider < BaseProvider
        protected

        def generate_prompt(resolver)
          request = Chat::Request.new      # Default Options
          request.merge!(options.to_hc)    # Agent Options
          request.merge!(resolver.context) # Action Options

          # @todo Request Validation?
          parameters = request.to_hc

          # Streaming
          if request.stream
            parameters[:stream] = ->(api_response_chunk) { process_stream(resolver, api_response_chunk) }
          end

          api_response = client.chat(parameters:)
          process_response(resolver, request, api_response)
        end

        def process_response(resolver, request, api_response)
          message  = if request.stream
            ActiveAgent::ActionPrompt::Message.new(content: api_response, role: :assistant)
          else
            api_message = api_response.dig("choices", 0, "message")
            ActiveAgent::ActionPrompt::Message.new(
              generation_id:     api_message["id"] || api_response["id"],
              content:           api_message["content"],
              role:              api_message["role"].intern,
              action_requested:  api_message["finish_reason"] == "tool_calls",
              raw_actions:       api_message["tool_calls"] || [],
              requested_actions: handle_actions(api_message["tool_calls"]),
              content_type:      resolver.context[:output_schema].present? ? "application/json" : "text/plain"
            )
          end

          ActiveAgent::GenerationProvider::Response.new(
            prompt: resolver,
            message: message,
            raw_request: request,
            raw_response: api_response,
          )
        end

        def process_stream(resolver, api_response_chunk)
          return unless api_response_chunk.dig("choices", 0)

          # If we have a delta, we need to update a message in the stack
          if (api_message = api_response_chunk.dig("choices", 0, "delta"))
            # If we have content, append it to the message
            if (content = api_message.dig("content")) && !content.blank?
              message               = resolver.streaming_message
              message.generation_id = api_response_chunk.dig("id")
              message.content       += content

            # if we have a tool call, we push a new message
            elsif api_message.dig("tool_calls") && api_message.dig("role")
              resolver.stream_messages << ActiveAgent::ActionPrompt::Message.new(
                generation_id:     api_response_chunk.fetch("id"),
                role:              api_message.dig("role").intern,
                action_requested:  api_response_chunk.dig("choices", 0, "finish_reason") == "tool_calls",
                raw_actions:       api_message.dig("tool_calls") || [],
                requested_actions: handle_actions(api_message.fetch("tool_calls")),
                content_type:      resolver.context[:output_schema].present? ? "application/json" : "text/plain"
              )
            end
          end

          # If this is the last api_response_chunk to be processed
          finished = api_response_chunk.dig("choices", 0, "finish_reason")

          resolver.stream_callback.call(message, content, finished) if content || finished
        end

        # def embeddings_response(response, request_params = nil)
        #   message = ActiveAgent::ActionPrompt::Message.new(content: response.dig("data", 0, "embedding"), role: "assistant")

        #   @response = ActiveAgent::GenerationProvider::Response.new(
        #     prompt: prompt,
        #     message: message,
        #     raw_response: response,
        #     raw_request: request_params
        #   )
        # end
      end
    end
  end
end
