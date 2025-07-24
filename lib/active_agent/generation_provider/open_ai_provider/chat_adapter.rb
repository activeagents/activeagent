require_relative "base_adapter"

module ActiveAgent
  module GenerationProvider
    class OpenAIProvider < Base
      class ChatAdapter < BaseAdapter
        def parameters
          params = {
            model: @model,
            messages: format_messages(@prompt.messages),
            temperature: @prompt.options[:temperature] || @config["temperature"] || 0.7
          }.compact

          # Add max_tokens if provided
          params[:max_tokens] = @prompt.options[:max_tokens] || @config["max_tokens"] if @prompt.options[:max_tokens] || @config["max_tokens"]

          # Only include tools if we're not using structured output and tools are properly formatted
          unless has_structured_output?
            tools = @prompt.actions
            if tools.present? && tools.all? { |tool| tool.is_a?(Hash) && tool.key?("type") }
              params[:tools] = tools
            end
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
          choice = response.dig("choices", 0)
          return nil unless choice

          message_data = choice["message"]
          content = message_data["content"]
          
          # Parse structured content if it's JSON
          if has_structured_output?
            content = parse_structured_content(content) if content
          end

          # Check for tool calls to determine if action is requested
          tool_calls = message_data["tool_calls"]
          action_requested = tool_calls.present?

          ActiveAgent::ActionPrompt::Message.new(
            content: content,
            role: message_data["role"].to_sym,
            generation_id: response["id"],
            action_requested: action_requested,
            tool_calls: tool_calls
          )
        end

        private

        def format_messages(messages)
          messages.map do |message|
            case message
            when Hash
              message
            when ActiveAgent::ActionPrompt::Message
              format_message(message)
            else
              { role: :user, content: message.to_s }
            end
          end
        end

        def format_message(message)
          formatted = {
            role: message.role.to_sym,
            content: message.content
          }

          # Add additional fields if present
          formatted[:name] = message.name if message.respond_to?(:name) && message.name
          formatted[:tool_calls] = message.tool_calls if message.respond_to?(:tool_calls) && message.tool_calls
          formatted[:tool_call_id] = message.tool_call_id if message.respond_to?(:tool_call_id) && message.tool_call_id

          formatted
        end
      end
    end
  end
end