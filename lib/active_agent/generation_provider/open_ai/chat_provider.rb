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
            parameters[:stream] = ->(chunk) { stream_process(resolver, chunk) }
          end

          api_response = client.chat(parameters:)

          response(resolver, request, api_response)
        end

        def response(resolver, request, raw_response)
          message  = if request.stream
            ActiveAgent::ActionPrompt::Message.new(content: raw_response, role: :assistant)
          else
            message_json = raw_response.dig("choices", 0, "message")
            ActiveAgent::ActionPrompt::Message.new(
              generate_id:       message_json["id"] || raw_response["id"],
              content:           message_json["content"],
              role:              message_json["role"].intern,
              action_requested:  message_json["finish_reason"] == "tool_calls",
              raw_actions:       message_json["tool_calls"] || [],
              requested_actions: handle_actions(message_json["tool_calls"]),
              content_type:      resolver.context[:output_schema].present? ? "application/json" : "text/plain"
            )
          end

          ActiveAgent::GenerationProvider::Response.new(
            prompt: resolver,
            message: message,
            raw_request: request,
            raw_response: raw_response,
          )
        end

        def stream_process(resolver, chunk)
          choice = chunk.dig("choices", 0)
          return unless choice

          # If this is the last chunk to be processed
          finished = choice.dig("finish_reason")

          # If we have a delta, we need to update a message in the stack
          if (delta = choice.dig("delta"))
            message = resolver.streaming_message

            # If we have content, append it to the message
            if (content = delta.dig("content")) && !content.blank?
              message.generation_id = chunk.dig("id")
              message.content       += content

            # if we have a tool call, we push a new message
            elsif delta.dig("tool_calls") && delta.dig("role")
              resolver.stream_messages << ActiveAgent::ActionPrompt::Message.new(
                generate_id:       chunk.fetch("id"),
                role:              delta.fetch("role").intern,
                action_requested:  choice.fetch("finish_reason") == "tool_calls",
                raw_actions:       delta.fetch("tool_calls") || [],
                requested_actions: handle_actions(delta.fetch("tool_calls")),
                content_type:      resolver.context[:output_schema].present? ? "application/json" : "text/plain"
              )
            end
          end

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
