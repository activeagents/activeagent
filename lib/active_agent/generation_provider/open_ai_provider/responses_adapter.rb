require_relative "base_adapter"

module ActiveAgent
  module GenerationProvider
    class OpenAIProvider < Base
      class ResponsesAdapter < BaseAdapter
        def parameters
          params = {
            model: @model,
            input: format_input(@prompt.messages),
            temperature: @prompt.options[:temperature] || @config["temperature"] || 0.7
          }.compact

          # Add max_tokens if provided
          params[:max_tokens] = @prompt.options[:max_tokens] || @config["max_tokens"] if @prompt.options[:max_tokens] || @config["max_tokens"]
          
          # Add previous_response_id if provided
          params[:previous_response_id] = @prompt.options[:previous_response_id] if @prompt.options[:previous_response_id]

          # Include tools if they are properly formatted objects
          tools = @prompt.actions
          if tools.present? && tools.all? { |tool| tool.is_a?(Hash) && (tool.key?("type") || tool.key?(:type)) }
            params[:tools] = tools
          end

          # Structured output support using OpenAI's structured outputs feature
          if @prompt.options[:json_schema]
            params[:response_format] = {
              type: "json_schema",
              json_schema: {
                name: @prompt.options[:json_schema][:name] || "response",
                description: @prompt.options[:json_schema][:description] || "Structured response",
                schema: @prompt.options[:json_schema][:schema] || @prompt.options[:json_schema],
                strict: @prompt.options[:json_schema][:strict] != false
              }
            }
          elsif @config["json_schema"]
            params[:response_format] = {
              type: "json_schema",
              json_schema: {
                name: @config["json_schema"]["name"] || "response",
                description: @config["json_schema"]["description"] || "Structured response",
                schema: @config["json_schema"]["schema"] || @config["json_schema"],
                strict: @config["json_schema"]["strict"] != false
              }
            }
          elsif @prompt.options[:response_format]
            params[:response_format] = @prompt.options[:response_format]
          elsif @config["response_format"]
            params[:response_format] = @config["response_format"]
          end

          params
        end

        def parse_response(response)
          # Handle responses API format which has output array
          outputs = response["output"]
          return nil unless outputs && outputs.is_a?(Array) && outputs.length > 0
          
          output = outputs.first
          content = nil
          tool_calls = []
          
          case output["type"]
          when "message"
            # Handle message type with content array
            content_items = output["content"]
            if content_items.is_a?(Array)
              # Multiple content items
              content_items.each do |item|
                case item["type"]
                when "text"
                  content = parse_text_content(item["text"])
                when "tool_call"
                  tool_calls << {
                    type: "function",
                    function: {
                      name: item["name"],
                      arguments: item["parameters"].to_json
                    }
                  }
                end
              end
            else
              # Single content item (should be a string)
              content = parse_text_content(content_items)
            end
          when "tool_call", "function_call"
            # Direct tool call
            tool_calls << {
              id: output["id"],
              type: "function",
              function: {
                name: output["name"],
                arguments: (output["parameters"] || output["arguments"] || {}).to_json
              }
            }
            content = "" # Tool calls typically don't have text content
          else
            # Fallback for other types
            content = output["content"] || output.to_s
          end

          # Check for tool calls to determine if action is requested
          action_requested = tool_calls.present?
          requested_actions = tool_calls.map { |call| 
            ActiveAgent::ActionPrompt::Action.new(
              id: call[:id],
              name: call.dig(:function, :name),
              params: JSON.parse(call.dig(:function, :arguments) || "{}")
            )
          } if action_requested

          ActiveAgent::ActionPrompt::Message.new(
            content: content,
            role: :assistant,
            generation_id: response["id"],
            action_requested: action_requested,
            requested_actions: requested_actions || [],
            tool_calls: tool_calls
          )
        end

        private

        def format_input(messages)
          case messages
          when Array
            if messages.length == 1
              message = messages.first
              # Single message - check if it needs special handling
              if message.respond_to?(:content_type) && message.content_type == "input_image"
                # Image input - format as multipart with text + image
                return [
                  { type: "text", text: "Please analyze this image." },
                  { type: "image_url", image_url: { url: message.content } }
                ]
              elsif message.respond_to?(:content)
                # Regular single message
                return message.content
              else
                return message.to_s
              end
            else
              # Multiple messages - format as multipart content array
              messages.map do |message|
                case message
                when ActiveAgent::ActionPrompt::Message
                  format_message_for_input(message)
                when Hash
                  format_content_item(message)
                when String
                  { type: "text", text: message }
                else
                  { type: "text", text: message.to_s }
                end
              end
            end
          when String
            messages
          else
            messages.to_s
          end
        end

        def format_message_for_input(message)
          if message.respond_to?(:content_type) && message.content_type == "input_image"
            {
              type: "image_url",
              image_url: { url: message.content }
            }
          elsif message.content.is_a?(String)
            { type: "text", text: message.content }
          elsif message.content.is_a?(Array)
            # Multi-part content
            message.content
          else
            { type: "text", text: message.content.to_s }
          end
        end

        def format_content_item(item)
          if item.key?("content") || item.key?(:content)
            # Message-like object
            content = item["content"] || item[:content]
            { type: "text", text: content.to_s }
          elsif item.key?("type") || item.key?(:type)
            # Already formatted content item
            item
          else
            # Generic hash, convert to text
            { type: "text", text: item.to_s }
          end
        end

        def parse_text_content(text)
          return text unless text.is_a?(String)
          
          # Parse structured content if it's JSON
          if has_structured_output?
            parse_structured_content(text)
          else
            text
          end
        end
      end
    end
  end
end