require_relative "base_adapter"
require "active_agent/generation_provider/response"
require "active_agent/generation_provider/base"

module ActiveAgent
  module GenerationProvider
    module OpenAIAdapters
      class ChatCompletionsAdapter < BaseAdapter
        
        def supports?(prompt)
          # Chat completions adapter is used when:
          # - No structured output schemas are present
          # - No multipart content in messages
          # - Standard text/tool calling scenarios
          !has_structured_output?(prompt) && !has_multipart_content?(prompt)
        end

        protected

        def perform_generation
          chat_response(@client.chat(parameters: chat_parameters))
        end

        def perform_embedding
          embeddings_response(@client.embeddings(parameters: embeddings_parameters))
        end

        private

        def has_structured_output?(prompt)
          prompt.options[:response_format] || prompt.options[:structured_output]
        end

        def has_multipart_content?(prompt)
          prompt.messages.any? do |message|
            message.content.is_a?(Array) || 
            message.content_type&.include?("multipart") ||
            message.content_type == "image_url" ||
            (message.content.is_a?(String) && message.content.start_with?("data:"))
          end
        end

        def chat_parameters
          {
            model: @prompt.options[:model] || default_model,
            messages: provider_messages(@prompt.messages),
            temperature: temperature,
            max_tokens: max_tokens,
            tools: format_tools_for_chat_completions(@prompt.actions),
            response_format: @prompt.options[:response_format]
          }.compact.tap do |params|
            params[:stream] = provider_stream if stream_enabled?
          end
        end

        def format_tools_for_chat_completions(actions)
          return nil unless actions&.any?
          
          actions.map do |action_schema|
            # The action_schema comes from jbuilder templates and should already be in the right format
            # { type: "function", function: { name: "...", description: "...", parameters: {...} } }
            if action_schema.is_a?(Hash)
              action_schema
            elsif action_schema.respond_to?(:to_h)
              action_schema.to_h
            else
              # Fallback for Action objects
              {
                type: "function",
                function: {
                  name: action_schema.name,
                  description: action_schema.description,
                  parameters: action_schema.parameters
                }
              }
            end
          end
        end

        def provider_messages(messages)
          messages.map do |message|
            provider_message = {
              role: message.role,
              tool_call_id: message.action_id.presence,
              name: message.action_name.presence,
              tool_calls: message.raw_actions.present? ? message.raw_actions[:tool_calls] : (message.requested_actions.map { |action| { type: "function", function: { name: action.name, arguments: action.params.to_json } } } if message.action_requested),
              generation_id: message.generation_id,
              content: message.content,
              type: message.content_type,
              charset: message.charset
            }.compact

            if message.content_type == "image_url" || (message.content.is_a?(String) && message.content.start_with?("data:"))
              provider_message[:content] = [
                {
                  type: "image_url",
                  image_url: { url: message.content }
                }
              ]
            end
            
            provider_message
          end
        end

        def provider_stream
          agent_stream = @prompt.options[:stream]
          message = ActiveAgent::ActionPrompt::Message.new(content: "", role: :assistant)
          @response = ActiveAgent::GenerationProvider::Response.new(prompt: @prompt, message: message)
          
          proc do |chunk, bytesize|
            new_content = chunk.dig("choices", 0, "delta", "content")
            if new_content && !new_content.blank?
              message.generation_id = chunk.dig("id")
              message.content += new_content

              agent_stream.call(message, new_content, false) do |message, new_content|
                yield message, new_content if block_given?
              end
            elsif chunk.dig("choices", 0, "delta", "tool_calls") && chunk.dig("choices", 0, "delta", "role")
              message = handle_message(chunk.dig("choices", 0, "delta"))
              @prompt.messages << message
              @response = ActiveAgent::GenerationProvider::Response.new(prompt: @prompt, message: message)
            end

            agent_stream.call(message, nil, true) do |message|
              yield message, nil if block_given?
            end
          end
        end

        def chat_response(response)
          return @response if stream_enabled?
          
          message_json = response.dig("choices", 0, "message")
          message_json["id"] = response.dig("id") if message_json["id"].blank?
          message = handle_message(message_json)

          @response = ActiveAgent::GenerationProvider::Response.new(
            prompt: @prompt, 
            message: message, 
            raw_response: response
          )
        end

        def handle_message(message_json)
          ActiveAgent::ActionPrompt::Message.new(
            generation_id: message_json["id"],
            content: message_json["content"],
            role: message_json["role"].intern,
            action_requested: message_json["finish_reason"] == "tool_calls",
            raw_actions: message_json["tool_calls"] || [],
            requested_actions: handle_actions(message_json["tool_calls"])
          )
        end

        def embeddings_parameters
          # Get text content from messages or prompt
          input_text = if @prompt.message&.content
            @prompt.message.content
          elsif @prompt.messages.any?
            @prompt.messages.last.content
          else
            ""
          end

          {
            model: @prompt.options[:embedding_model] || "text-embedding-3-large",
            input: input_text
          }
        end

        def embeddings_response(response)
          message = ActiveAgent::ActionPrompt::Message.new(
            content: response.dig("data", 0, "embedding"), 
            role: "assistant"
          )

          @response = ActiveAgent::GenerationProvider::Response.new(
            prompt: @prompt, 
            message: message, 
            raw_response: response
          )
        end
      end
    end
  end
end
