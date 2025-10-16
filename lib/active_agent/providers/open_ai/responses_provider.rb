require_relative "_base_provider"
require_relative "responses/request"

module ActiveAgent
  module Providers
    module OpenAI
      # @see https://platform.openai.com/docs/api-reference/responses
      class ResponsesProvider < BaseProvider
        attr_internal :request, :input_stack, :output_stack, :stream_finished

        def initialize(...)
          super

          self.request      = Responses::Request.new(context)
          self.input_stack  = []
          self.output_stack = []
        end

        protected

        # @return response [ActiveAgent::Providers::Response]
        def resolve_prompt
          # Apply Tool/Function Messages
          request.input = [ *request.input_list, *input_stack ] unless input_stack.empty?
          # @todo Bubble up Invalid Requests

          ## Prepare Executation Environment
          self.output_stack = []
          parameters = request.to_hc
          if request.stream
            parameters[:stream] = process_stream if request.stream
            self.stream_finished = false
          end

          ## Execute
          api_response = client.responses.create(parameters:)
          process_finished(api_response.presence&.deep_symbolize_keys)
        end

        # @return response [ActiveAgent::Providers::Response]
        def process_finished(api_response = nil)
          # elsif (api_message = api_response["output"].find { it["type"] == "message" })
          #   api_message["id"] = api_response.dig("id") if api_message["id"].blank?
          #   ActiveAgent::ActionPrompt::Message.new(
          #     generation_id:    api_message["id"],
          #     content:          api_message["content"].first["text"],
          #     role:             api_message["role"].intern,
          #     action_requested: api_message["finish_reason"] == "tool_calls",
          #     raw_actions:      api_message["tool_calls"] || [],
          #     content_type:     context[:output_schema].present? ? "application/json" : "text/plain"
          #   )
          # end

          binding.pry if api_response
          if (api_message = api_response&.dig(:choices, 0, :message))
            output_stack.push(api_message)
          end

          if output_stack.any? { it[:type] == "function_call" }
            tool_calls = output_stack.extract! { it[:type] == "function_call" }

            process_tool_calls(tool_calls)
            resolve_prompt
          else
            ActiveAgent::Providers::Response.new(
              prompt: resolver,
              message: output_stack.last,
              raw_request: self.request,
              raw_response: api_response,
            )
          end
        end

        def process_stream_chunk(api_response_chunk)
          case api_response_chunk[:type]
          # Response Created
          when "response.created", "response.in_progress"

          # -> Message Created
          when "response.output_item.added"
            process_stream_output_item_added(api_response_chunk)

          # -> -> Content Part Create
          when "response.content_part.added"

          # -> -> -> Content Text Append
          when "response.output_text.delta"
            message = output_stack.find { it[:id] == api_response_chunk[:item_id] }
            message[:content] += api_response_chunk[:delta]
            stream_callback.call(message, api_response_chunk[:delta], false)

          # -> -> -> Content Text Completed [Full Text]
          when "response.output_text.done"
            message = output_stack.find { it[:id] == api_response_chunk[:item_id] }
            message[:content] = api_response_chunk[:text]
            stream_callback.call(message, api_response_chunk[:text], false)

          # -> -> -> Content Function Call Append
          when "response.function_call_arguments.delta", "response.function_call_arguments.done"
          # No-Op: Wait for FC to Land

          # -> -> Content Part Completed [Full Part]
          when "response.content_part.done"

          # -> Message Completed
          when "response.output_item.done"
            process_stream_output_item_done(api_response_chunk)

          # Response Completed
          when "response.completed"
            # Once we are finished, close out and run tooling callbacks (Recursive)
            process_finished

            # Then we can close out the stream
            return if stream_finished
            self.stream_finished = true
            stream_callback.call(output_stack.last, nil, true)
          end
        end

        def process_stream_output_item_added(api_response_chunk)
          case api_response_chunk.dig(:item, :type)
          when "message"
            # PATCH: API returns an empty array instead of empty string due to a bug in their serialization
            output_stack << { content: "" }.merge(api_response_chunk[:item].compact_blank)
          when "function_call"
            # No-Op: Wait for FC to Land (-> response.output_item.done)
          else
            fail "Unexpected Item Type: #{type}"
          end
        end

        def process_stream_output_item_done(api_response_chunk)
          case api_response_chunk.dig(:item, :type)
          when "message"
            # No-Op: Message Up to Date
          when "function_call"
            output_stack << api_response_chunk.dig(:item)
          else
            fail "Unexpected Item Type: #{type}"
          end
        end

        # @return void
        def process_tool_calls(api_tool_calls)
          api_tool_calls.each do |api_tool_call|
            tool_call_id = api_tool_call[:call_id]
            content      = process_tool_call_function(api_tool_call).to_json
            message      = Responses::Requests::Inputs::ToolMessage.new(tool_call_id:, content:)

            input_stack.push(message.to_hc)
          end
        end

        # @return result [Unknown]
        def process_tool_call_function(api_function_call)
          name   = api_function_call[:name]
          kwargs = JSON.parse(api_function_call[:arguments], symbolize_names: true) if api_function_call[:arguments]

          function_callback.call(name, **kwargs)
        end
      end
    end
  end
end
