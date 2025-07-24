require_relative "base_adapter"
require "active_agent/generation_provider/response"
require "active_agent/generation_provider/base"
require "securerandom"

module ActiveAgent
  module GenerationProvider
    module OpenAIAdapters
      class ResponsesAdapter < BaseAdapter
        
        def supports?(prompt)
          # Responses adapter is used when:
          # - Structured output schemas are present
          # - Multipart content in messages (images, files)
          # - Advanced features requiring the Responses API
          # - For now, let's only use it for structured output and multipart content
          has_structured_output?(prompt) || has_multipart_content?(prompt) || has_file_input?(prompt) || has_image_input?(prompt)
        end

        protected

        def perform_generation
          responses_response(@client.responses.create(parameters: responses_parameters))
        end

        def perform_embedding
          # Embeddings are still handled through the regular API
          embeddings_response(@client.embeddings(parameters: embeddings_parameters))
        end

        private

        def has_structured_output?(prompt)
          prompt.options[:structured_output] || prompt.options[:output_schema]
        end

        def has_multipart_content?(prompt)
          prompt.messages.any? do |message|
            message.content.is_a?(Array) || 
            message.content_type&.include?("multipart") ||
            message.content_type == "image_url" ||
            (message.content.is_a?(String) && message.content.start_with?("data:")) ||
            message.input_file_id.present?
          end
        end

        def has_file_input?(prompt)
          prompt.options[:input_file_id] || 
          prompt.messages.any? { |m| m.input_file_id.present? }
        end

        def has_image_input?(prompt)
          prompt.options[:input_image] ||
          prompt.options[:input_image_url]
        end

        def responses_parameters
          base_params = {
            model: @prompt.options[:model] || default_model,
            temperature: temperature,
            max_tokens: max_tokens
          }.compact

          # Add input based on prompt structure - Responses API supports both string and array content
          if @prompt.options[:input_text]
            base_params[:input] = [
              {
                role: "user",
                content: @prompt.options[:input_text]
              }
            ]
          elsif @prompt.options[:input_file_id]
            base_params[:input] = [
              {
                role: "user", 
                content: [{ type: "input_file", input_file: { file_id: @prompt.options[:input_file_id] } }]
              }
            ]
          elsif @prompt.options[:input_image]
            base_params[:input] = prepare_image_input(@prompt.options[:input_image])
          elsif has_multipart_content?(@prompt)
            base_params[:input] = prepare_multipart_input
          else
            # Default to simple text input from the last user message
            last_user_message = @prompt.messages.reverse.find { |m| m.role == :user }
            content_text = last_user_message&.content || ""
            base_params[:input] = [
              {
                role: "user",
                content: content_text
              }
            ]
          end

          # Add tools if present
          if @prompt.actions.present?
            base_params[:tools] = @prompt.actions.map do |action_schema|
              # Convert from Chat Completions format to Responses API format
              # Chat Completions format: { type: "function", function: { name: "...", description: "...", parameters: {...} } }
              # Responses API format: { type: "function", name: "...", description: "...", parameters: {...} }
              if action_schema.is_a?(Hash) && action_schema["function"]
                {
                  "type" => "function",
                  "name" => action_schema["function"]["name"],
                  "description" => action_schema["function"]["description"],
                  "parameters" => action_schema["function"]["parameters"]
                }
              elsif action_schema.respond_to?(:name) && action_schema.respond_to?(:description)
                # Handle Action objects
                {
                  "type" => "function",
                  "name" => action_schema.name,
                  "description" => action_schema.description,
                  "parameters" => action_schema.parameters
                }
              else
                # Fallback - assume it's already in the right format
                action_schema
              end
            end
          end

          # Add structured output schema if present - use correct Responses API format
          if @prompt.options[:structured_output]
            base_params[:text] = {
              format: {
                type: "json_schema",
                name: @prompt.options[:structured_output][:name] || "structured_output",
                schema: @prompt.options[:structured_output][:schema] || @prompt.options[:structured_output],
                strict: @prompt.options[:structured_output][:strict] || true
              }
            }
          end

          # Add previous response for follow-up conversations
          if @prompt.options[:previous_response_id]
            base_params[:previous_response_id] = @prompt.options[:previous_response_id]
          end

          # Add streaming if enabled
          if stream_enabled?
            base_params[:stream] = provider_stream
          end

          base_params
        end

        def prepare_image_input(image_data)
          if image_data.is_a?(String)
            if image_data.start_with?("data:")
              # Base64 encoded image
              [
                {
                  "role" => "user",
                  "content" => [
                    {
                      "type" => "input_image",
                      "image_url" => image_data
                    }
                  ]
                }
              ]
            elsif image_data.start_with?("http")
              # Image URL
              [
                {
                  "role" => "user", 
                  "content" => [
                    {
                      "type" => "input_image",
                      "image_url" => image_data
                    }
                  ]
                }
              ]
            else
              # File path - would need to be uploaded first
              raise ArgumentError, "File paths not supported directly. Please upload file and use file_id"
            end
          elsif image_data.is_a?(Hash) && image_data[:file_id]
            [
              {
                "role" => "user",
                "content" => [
                  {
                    "type" => "input_file",
                    "input_file" => { "file_id" => image_data[:file_id] }
                  }
                ]
              }
            ]
          else
            raise ArgumentError, "Invalid image input format"
          end
        end

        def prepare_multipart_input
          messages = []
          current_message = { "role" => "user", "content" => [] }
          
          @prompt.messages.each do |message|
            if message.role == :system
              # System messages become instructions in Responses API - skip for input
              next
            end

            if message.content_type == "image_url" || (message.content.is_a?(String) && message.content.start_with?("data:"))
              current_message["content"] << {
                "type" => "input_image",
                "image_url" => message.content
              }
            elsif message.input_file_id.present?
              current_message["content"] << {
                "type" => "input_file", 
                "input_file" => { "file_id" => message.input_file_id }
              }
            elsif message.content.is_a?(Array)
              # Handle multipart content
              message.content.each do |part|
                case part["type"]
                when "text", "input_text"
                  current_message["content"] << {
                    "type" => "input_text",
                    "text" => part["text"]
                  }
                when "image_url", "input_image"
                  if part["image_url"]
                    current_message["content"] << {
                      "type" => "input_image", 
                      "image_url" => part["image_url"]["url"] || part["image_url"]
                    }
                  elsif part["input_image"]
                    # Handle nested input_image format - extract the data/url
                    image_data = part["input_image"]["data"] || part["input_image"]["url"] || part["input_image"]
                    current_message["content"] << {
                      "type" => "input_image",
                      "image_url" => image_data
                    }
                  end
                when "file", "input_file"
                  if part["file_id"]
                    current_message["content"] << {
                      "type" => "input_file",
                      "input_file" => { "file_id" => part["file_id"] }
                    }
                  elsif part["filename"] && part["file_data"]
                    # Handle file data directly (would typically need upload first)
                    current_message["content"] << {
                      "type" => "input_file",
                      "input_file" => {
                        "filename" => part["filename"],
                        "data" => part["file_data"]
                      }
                    }
                  end
                end
              end
            else
              current_message["content"] << {
                "type" => "input_text",
                "text" => message.content
              }
            end
          end

          if current_message["content"].any?
            messages << current_message
          else
            # Fallback empty message
            messages << {
              "role" => "user",
              "content" => [
                {
                  "type" => "input_text", 
                  "text" => ""
                }
              ]
            }
          end

          messages
        end

        def provider_stream
          agent_stream = @prompt.options[:stream]
          content = ""
          
          proc do |chunk, bytesize|
            if chunk["type"] == "response.output_text.delta"
              delta = chunk["delta"]
              content += delta if delta
              
              message = ActiveAgent::ActionPrompt::Message.new(
                content: content,
                role: :assistant,
                generation_id: chunk["response_id"]
              )

              @response = ActiveAgent::GenerationProvider::Response.new(prompt: @prompt, message: message)

              agent_stream.call(message, delta, false) do |message, new_content|
                yield message, new_content if block_given?
              end
            elsif chunk["type"] == "response.done"
              message = ActiveAgent::ActionPrompt::Message.new(
                content: content,
                role: :assistant,
                generation_id: chunk["response_id"]
              )

              agent_stream.call(message, nil, true) do |message|
                yield message, nil if block_given?
              end
            elsif chunk["type"] == "response.output_tool_calls"
              # Handle tool calls in streaming
              tool_calls = chunk["tool_calls"]
              message = ActiveAgent::ActionPrompt::Message.new(
                content: content,
                role: :assistant,
                generation_id: chunk["response_id"],
                action_requested: true,
                raw_actions: tool_calls,
                requested_actions: handle_tool_calls(tool_calls)
              )

              @response = ActiveAgent::GenerationProvider::Response.new(prompt: @prompt, message: message)
            end
          end
        end

        def responses_response(response)
          return @response if stream_enabled?

          # Handle different response types from Responses API
          if response["output"] && response["output"].any?
            output = response["output"].first
            
            case output["type"]
            when "text"
              content = output.dig("content", 0, "text")
              message = ActiveAgent::ActionPrompt::Message.new(
                content: content,
                role: :assistant,
                generation_id: response["id"]
              )
            when "function_call"
              # Handle single function call in Responses API format
              tool_call = {
                "id" => "function_call_#{SecureRandom.hex(8)}",
                "name" => output["name"],
                "arguments" => output["arguments"]
              }
              
              message = ActiveAgent::ActionPrompt::Message.new(
                content: "",
                role: :assistant,
                generation_id: response["id"],
                action_requested: true,
                raw_actions: [tool_call],
                requested_actions: handle_tool_calls([tool_call])
              )
            when "tool_calls"
              # Handle multiple tool calls if this format exists
              tool_calls = output["tool_calls"]
              message = ActiveAgent::ActionPrompt::Message.new(
                content: "",
                role: :assistant,
                generation_id: response["id"],
                action_requested: true,
                raw_actions: tool_calls,
                requested_actions: handle_tool_calls(tool_calls)
              )
            else
              # Fallback for unknown output types
              content = output["content"]&.is_a?(Array) ? output["content"].map { |c| c["text"] }.join : output["content"]
              message = ActiveAgent::ActionPrompt::Message.new(
                content: content || "",
                role: :assistant,
                generation_id: response["id"]
              )
            end
          else
            # Empty response
            message = ActiveAgent::ActionPrompt::Message.new(
              content: "",
              role: :assistant,
              generation_id: response["id"]
            )
          end

          @response = ActiveAgent::GenerationProvider::Response.new(
            prompt: @prompt,
            message: message,
            raw_response: response
          )
        end

        def handle_tool_calls(tool_calls)
          return [] if tool_calls.nil? || tool_calls.empty?

          tool_calls.map do |tool_call|
            ActiveAgent::ActionPrompt::Action.new(
              id: tool_call["id"],
              name: tool_call["name"],
              params: tool_call["arguments"] || {}
            )
          end
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
