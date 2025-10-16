require_relative "_base_provider"
require_relative "responses/request"

module ActiveAgent
  module GenerationProvider
    module OpenAI
      # @see https://platform.openai.com/docs/api-reference/responses
      class ResponsesProvider < BaseProvider
        protected

        # @return response [ActiveAgent::GenerationProvider::Response]
        def resolve_prompt(resolver)
          request = Responses::Request.new # Default Options
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
          resolver.message_stack.replace(request.input_list)

          ## Execute
          api_response = client.responses.create(parameters:)
          process_finished(resolver, api_response.presence&.deep_symbolize_keys)
        end

        # @return response [ActiveAgent::GenerationProvider::Response]
        def process_finished(resolver, api_response = nil)
          binding.pry if api_response

          # elsif (api_message = api_response["output"].find { it["type"] == "message" })
          #   api_message["id"] = api_response.dig("id") if api_message["id"].blank?
          #   ActiveAgent::ActionPrompt::Message.new(
          #     generation_id:    api_message["id"],
          #     content:          api_message["content"].first["text"],
          #     role:             api_message["role"].intern,
          #     action_requested: api_message["finish_reason"] == "tool_calls",
          #     raw_actions:      api_message["tool_calls"] || [],
          #     content_type:     resolver.context[:output_schema].present? ? "application/json" : "text/plain"
          #   )
          # end

          if (api_message = api_response&.dig(:choices, 0, :message))
            resolver.message_stack.push(api_message)
          end

          if (tool_calls = resolver.message_stack.last[:tool_calls])
            process_tool_calls(resolver, tool_calls)
            generate_prompt(resolver)
          else
            ActiveAgent::GenerationProvider::Response.new(
              prompt: resolver,
              message: resolver.message_stack.last,
              raw_request: resolver.request,
              raw_response: api_response,
            )
          end
        end

        def process_stream_chunk(resolver, api_response_chunk)
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
            message = resolver.message_stack.find { it[:id] == api_response_chunk[:item_id] }
            message[:content] += api_response_chunk[:delta]
            resolver.stream_callback.call(message, api_response_chunk[:delta], false)

          # -> -> -> Content Text Completed [Full Text]
          when "response.output_text.done"
            message = resolver.message_stack.find { it[:id] == api_response_chunk[:item_id] }
            message[:content] = api_response_chunk[:text]
            resolver.stream_callback.call(message, api_response_chunk[:text], false)

          # -> -> -> Content Function Call Append
          when "response.function_call_arguments.delta", "response.function_call_arguments.done"
          # No-Op: Wait for FC to Land

          # -> -> Content Part Completed [Full Part]
          when "response.content_part.done"

          # -> Message Completed
          when "response.output_item.done"
            process_stream_output_item_done(resolver, api_response_chunk)

          # Response Completed
          when "response.completed"
            # Once we are finished, close out and run tooling callbacks (Recursive)
            process_finished(resolver)

            # Then we can close out the stream
            # @todo Debounce the close up.
            resolver.stream_callback.call(resolver.message_stack.last, nil, true)
          end
        end

        def process_stream_output_item_added(resolver, api_response_chunk)
          case api_response_chunk.dig(:item, :type)
          when "message"
            # PATCH: API returns an empty array instead of empty string due to a bug in their serialization
            resolver.message_stack << { content: "" }.merge(api_response_chunk[:item].compact_blank)
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
            resolver.message_stack << api_response_chunk.dig(:item)
          else
            fail "Unexpected Item Type: #{type}"
          end
        end
      end
    end
  end
end
