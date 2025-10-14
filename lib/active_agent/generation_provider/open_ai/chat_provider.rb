require_relative "../_base_provider"

module ActiveAgent
  module GenerationProvider
    module OpenAI
      class ChatProvider < BaseProvider
        protected

        def generate_prompt(prompt)
          parameters = generate_prompt_parameters(prompt)

          if prompt.options[:stream] || options.stream
            parameters[:stream] = provider_stream
            @streaming_request_params = parameters
          end

          response(client.chat(parameters:), parameters)
        end

        # Override from StreamProcessing module
        def process_stream_chunk(chunk, message, agent_stream)
          new_content = chunk.dig("choices", 0, "delta", "content")
          if new_content && !new_content.blank?
            message.generation_id = chunk.dig("id")
            message.content += new_content
            # Call agent_stream directly without the block to avoid double execution
            agent_stream&.call(message, new_content, false, prompt.action_name)
          elsif chunk.dig("choices", 0, "delta", "tool_calls") && chunk.dig("choices", 0, "delta", "role")
            message = handle_message(chunk.dig("choices", 0, "delta"))
            prompt.messages << message
            @response = ActiveAgent::GenerationProvider::Response.new(
              prompt:,
              message:,
              raw_response: chunk,
              raw_request: @streaming_request_params
            )
          end

          if chunk.dig("choices", 0, "finish_reason")
            finalize_stream(message, agent_stream)
          end
        end

        # Override from MessageFormatting module to handle OpenAI image format
        def format_image_content(message)
          [ {
            type: "image_url",
            image_url: { url: message.content }
          } ]
        end

        # Override from ParameterBuilder to add web_search_options for Chat API
        def build_provider_parameters(prompt)
          # Check if we're using a model that supports web_search_options in Chat API
          if WEB_SEARCH_MODELS.include?(prompt.options[:model] || options.model) && prompt.options[:web_search]
            params[:web_search_options] = build_web_search_options(prompt.options[:web_search])
          end

          params
        end

        def build_web_search_options(web_search_config)
          options = {}

          if web_search_config.is_a?(Hash)
            options[:search_context_size] = web_search_config[:search_context_size] if web_search_config[:search_context_size]

            if web_search_config[:user_location]
              options[:user_location] = {
                type: "approximate",
                approximate: web_search_config[:user_location]
              }
            end
          end

          options
        end

        def response(response, request_params = nil)
          return @response if prompt.options[:stream]
          message_json = response.dig("choices", 0, "message")
          message_json["id"] = response.dig("id") if message_json["id"].blank?
          message = handle_message(message_json)

          update_context(prompt: prompt, message: message, response: response)

          @response = ActiveAgent::GenerationProvider::Response.new(
            prompt: prompt,
            message: message,
            raw_response: response,
            raw_request: request_params
          )
        end

        def handle_message(message_json)
          ActiveAgent::ActionPrompt::Message.new(
            generation_id: message_json["id"],
            content: message_json["content"],
            role: message_json["role"].intern,
            action_requested: message_json["finish_reason"] == "tool_calls",
            raw_actions: message_json["tool_calls"] || [],
            requested_actions: handle_actions(message_json["tool_calls"]),
            content_type: prompt.output_schema.present? ? "application/json" : "text/plain"
          )
        end

        def embeddings_response(response, request_params = nil)
          message = ActiveAgent::ActionPrompt::Message.new(content: response.dig("data", 0, "embedding"), role: "assistant")

          @response = ActiveAgent::GenerationProvider::Response.new(
            prompt: prompt,
            message: message,
            raw_response: response,
            raw_request: request_params
          )
        end
      end
    end
  end
end
