require_relative "_base_provider"
require_relative "responses/request"

module ActiveAgent
  module GenerationProvider
    module OpenAI
      # @see https://platform.openai.com/docs/api-reference/responses
      class ResponsesProvider < BaseProvider
        protected

        def generate_prompt(resolver)
          request = Responses::Request.new # Default Options
          request.merge!(options.to_hc)    # Agent Options
          request.merge!(resolver.context) # Action Options

          # @todo Request Validation?
          parameters = request.to_hc

          # Streaming
          if request.stream
            parameters[:stream] = ->(api_response_chunk) { process_stream(resolver, api_response_chunk.deep_symbolize_keys) }
          end

          api_response = client.responses.create(parameters:)
          process_response(resolver, request, api_response)
        end

        def process_response(resolver, request, api_response)
          message = if request.stream
            ActiveAgent::ActionPrompt::Message.new(content: api_response, role: :assistant)
          elsif (api_message = api_response["output"].find { it["type"] == "message" })
            api_message["id"] = api_response.dig("id") if api_message["id"].blank?
            ActiveAgent::ActionPrompt::Message.new(
              generation_id:    api_message["id"],
              content:          api_message["content"].first["text"],
              role:             api_message["role"].intern,
              action_requested: api_message["finish_reason"] == "tool_calls",
              raw_actions:      api_message["tool_calls"] || [],
              content_type:     resolver.context[:output_schema].present? ? "application/json" : "text/plain"
            )
          end

          ActiveAgent::GenerationProvider::Response.new(
            prompt: resolver,
            message:,
            raw_request: request,
            raw_response: api_response
          )
        end

        def process_stream(resolver, api_response_chunk)
          case api_response_chunk[:type]
          # Response Created
          when "response.created", "response.in_progress"

          # -> Message Created
          when "response.output_item.added"
            process_stream_output_item_added(resolver, api_response_chunk)

          # -> -> Content Part Create
          when "response.content_part.added"

          # -> -> -> Content Text Append
          when "response.output_text.delta"
            message = resolver.streaming_message_find(api_response_chunk[:item_id])
            message.content += api_response_chunk[:delta]
            resolver.stream_callback.call(message, api_response_chunk[:delta], false)

          # -> -> -> Content Text Completed [Full Text]
          when "response.output_text.done"
            message = resolver.streaming_message_find(api_response_chunk[:item_id])
            message.content = api_response_chunk[:text]
            resolver.stream_callback.call(message, api_response_chunk[:text], false)

          # -> -> -> Content Function Call Append
          when "response.function_call_arguments.delta", "response.function_call_arguments.done"
          # No-Op: Wait for FC to Land

          # -> -> Content Part Completed [Full Part]
          when "response.content_part.done"

          # -> Message Completed
          when "response.output_item.done"

          # Response Completed
          when "response.completed"
            resolver.stream_callback.call(message, nil, true)
          end
        end

        def process_stream_output_item_added(resolver, api_response_chunk)
          case api_response_chunk.dig(:item, :type)
          when "message"
            resolver.stream_messages << ActiveAgent::ActionPrompt::Message.new(
              generation_id: api_response_chunk.dig(:item, :id),
              role:          api_response_chunk.dig(:item, :role).intern
            )
          when "function_call"
            # No-Op: Wait for FC to Land (-> response.output_item.done)
          else
            fail "Unexpected Item Type: #{type}"
          end
        end

        def process_stream_output_item_done(resolver, api_response_chunk)
          case api_response_chunk.dig(:item, :type)
          when "message"
            # No-Op: Message Up to Date
          when "function_call"
            resolver.stream_messages << ActiveAgent::ActionPrompt::Message.new(
              generation_id:     api_response_chunk.dig(:item, :id),
              # action_requested:  api_response_chunk.dig("choices", 0, "finish_reason") == "tool_calls",
              # raw_actions:       api_message.dig("tool_calls") || [],
              # requested_actions: handle_actions(api_message.fetch("tool_calls")),
              # content_type:      resolver.context[:output_schema].present? ? "application/json" : "text/plain"
            )
          else
            fail "Unexpected Item Type: #{type}"
          end
        end
      end
    end
  end
end
