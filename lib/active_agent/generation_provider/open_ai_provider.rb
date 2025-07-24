begin
  gem "ruby-openai", "~> 8.1.0"
  require "openai"
rescue LoadError
  raise LoadError, "The 'ruby-openai' gem is required for OpenAIProvider. Please add it to your Gemfile and run `bundle install`."
end

require "securerandom"
require "active_agent/action_prompt/action"
require_relative "base"
require_relative "response"
require_relative "open_ai_provider/base_adapter"
require_relative "open_ai_provider/chat_adapter"
require_relative "open_ai_provider/responses_adapter"
require_relative "open_ai_provider/embeddings_adapter"

module ActiveAgent
  module GenerationProvider
    class OpenAIProvider < Base
      def initialize(config, prompt: nil)
        super
        @api_key = config["api_key"]
        @model_name = config["model"] || "gpt-4o-mini"

        @client = if (@host = config["host"])
          OpenAI::Client.new(uri_base: @host, access_token: @api_key)
        else
          OpenAI::Client.new(access_token: @api_key)
        end
      end

      def generate(prompt)
        @prompt = prompt

        chat_prompt(parameters: prompt_parameters)
      rescue => e
        error_message = e.respond_to?(:message) ? e.message : e.to_s
        raise GenerationProviderError, error_message
      end

      def respond(prompt)
        @prompt = prompt

        responses_prompt(parameters: responses_parameters)
      rescue => e
        error_message = e.respond_to?(:message) ? e.message : e.to_s
        raise GenerationProviderError, error_message
      end

      def embed(prompt)
        @prompt = prompt

        embeddings_prompt(parameters: embeddings_parameters)
      rescue => e
        error_message = e.respond_to?(:message) ? e.message : e.to_s
        raise GenerationProviderError, error_message
      end

      private

      def provider_stream
        agent_stream = prompt.options[:stream]

        message = ActiveAgent::ActionPrompt::Message.new(content: "", role: :assistant)

        @response = ActiveAgent::GenerationProvider::Response.new(prompt:, message:)
        proc do |chunk, bytesize|
          # Handle both chat API and responses API streaming formats
          if chunk["type"] == "response.output_text.delta"
            # Responses API streaming format
            new_content = chunk["delta"]
            if new_content && !new_content.blank?
              message.generation_id = chunk.dig("response_id") || chunk.dig("id")
              message.content += new_content

              agent_stream.call(message, new_content, false) do |message, new_content|
                yield message, new_content if block_given?
              end
            end
          else
            # Chat API streaming format
            new_content = chunk.dig("choices", 0, "delta", "content")
            if new_content && !new_content.blank?
              message.generation_id = chunk.dig("id")
              message.content += new_content

              agent_stream.call(message, new_content, false) do |message, new_content|
                yield message, new_content if block_given?
              end
            elsif chunk.dig("choices", 0, "delta", "tool_calls") && chunk.dig("choices", 0, "delta", "role")
              message = handle_message(chunk.dig("choices", 0, "delta"))
              prompt.messages << message
              @response = ActiveAgent::GenerationProvider::Response.new(prompt:, message:)
            end
          end

          agent_stream.call(message, nil, true) do |message|
            yield message, nil if block_given?
          end
        end
      end

      def responses_parameters(model: @prompt.options[:model] || @model_name, 
                             input: format_responses_input(@prompt.messages), 
                             temperature: @prompt.options[:temperature] || @config["temperature"] || 0.7, 
                             tools: @prompt.actions,
                             previous_response_id: @prompt.options[:previous_response_id])
        params = {
          model: model,
          input: input,
          temperature: temperature,
          max_tokens: @prompt.options[:max_tokens] || @config["max_tokens"],
          previous_response_id: previous_response_id
        }.compact

        # Include tools if they are properly formatted objects
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

      def format_responses_input(messages)
        # The responses API input format follows specific patterns:
        # - For single text message: can be a string
        # - For multipart content: array of content objects
        # - For conversation history: array of message objects with role and content
        
        if messages.length == 1
          message = messages.first
          case message.content_type
          when "text/plain", nil
            # Simple text input
            return message.content
          when "input_image", "image_url"
            # Multipart: text + image
            return [
              { type: "text", text: "Please analyze this image." },
              { type: "image_url", image_url: { url: message.content } }
            ]
          when "input_file"
            # Multipart: text + file (Note: file handling may need specific encoding)
            return [
              { type: "text", text: "Please analyze this file." },
              { type: "input_file", input_file: { data: message.content, filename: message.file_name } }
            ]
          else
            return message.content
          end
        else
          # Multiple messages - format as multipart content array
          content_items = []
          
          messages.each do |message|
            case message.content_type
            when "input_image", "image_url"
              content_items << {
                type: "image_url",
                image_url: { url: message.content }
              }
            when "input_file"
              content_items << {
                type: "input_file", 
                input_file: { data: message.content, filename: message.file_name }
              }
            else
              content_items << {
                type: "text",
                text: message.content
              }
            end
          end
          
          return content_items
        end
      end
      
      def prompt_parameters(model: @prompt.options[:model] || @model_name, messages: @prompt.messages, temperature: @prompt.options[:temperature] || @config["temperature"] || 0.7, tools: @prompt.actions)
        params = {
          model: model,
          messages: provider_messages(messages),
          temperature: temperature,
          max_tokens: @prompt.options[:max_tokens] || @config["max_tokens"],
          tools: tools.presence
        }.compact

        # Only include tools if we're not using structured output and tools are properly formatted
        # Structured output mode should focus solely on generating the structured response
        unless @prompt.options[:json_schema] || @config["json_schema"]
          # Only include tools if they are properly formatted objects (not just strings)
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

      def provider_messages(messages)
        messages.map do |message|
          provider_message = {
            role: message.role,
            tool_call_id: message.action_id.presence,
            name: message.action_name.presence,
            tool_calls: message.raw_actions.present? ? message.raw_actions[:tool_calls] : (message.requested_actions.map { |action| { type: "function", name: action.name, arguments: action.params.to_json } } if message.action_requested),
            generation_id: message.generation_id,
            content: message.content,
            type: message.content_type,
            charset: message.charset
          }.compact

          if message.content_type == "image_url" || message.content[0..4] == "data:"
            provider_message[:type] = "image_url"
            provider_message[:image_url] = { url: message.content }
          end
          
          if message.content_type == "input_image" || message.content[0..4] == "data:"
            provider_message[:type] = "input_image"
            provider_message[:image_url] = { url: message.content }
          end

          if message.content_type == "input_file" && message.content[0..4] == "data:"
            provider_message[:type] = "input_file"
            provider_message[:file_data] = message.content
            provider_message[:file_name] = message.file_name if message.file_name.present?
          end
          provider_message
        end
      end

      def chat_response(response)
        return @response if prompt.options[:stream]
        message_json = response.dig("choices", 0, "message")
        message_json["id"] = response.dig("id") if message_json["id"].blank?

        # Handle structured outputs by parsing JSON content
        if has_structured_output? && message_json["content"].is_a?(String)
          begin
            parsed_content = JSON.parse(message_json["content"], symbolize_names: true)
            message_json["content"] = parsed_content
          rescue JSON::ParserError
            # If JSON parsing fails, leave content as string for debugging
          end
        end

        message = handle_message(message_json)

        update_context(prompt: prompt, message: message, response: response)

        @response = ActiveAgent::GenerationProvider::Response.new(prompt: prompt, message: message, raw_response: response)
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

      def handle_actions(tool_calls)
        return [] if tool_calls.nil? || tool_calls.empty?

        tool_calls.map do |tool_call|
          next if tool_call["function"].nil? || tool_call["function"]["name"].blank?
          args = tool_call["function"]["arguments"].blank? ? nil : JSON.parse(tool_call["function"]["arguments"], { symbolize_names: true })

          ActiveAgent::ActionPrompt::Action.new(
            id: tool_call["id"],
            name: tool_call.dig("function", "name"),
            params: args
          )
        end.compact
      end

      # Check if structured output is being used
      def has_structured_output?
        structured_formats = [ "json_schema", "json_object" ]

        # Check if response_format indicates structured output
        response_format = @prompt.options[:response_format] || config["response_format"]
        if response_format.is_a?(Hash) && structured_formats.include?(response_format[:type] || response_format["type"])
          return true
        end

        # Check if json_schema is specified
        @prompt.options[:json_schema] || config["json_schema"]
      end

      def chat_prompt(parameters: prompt_parameters)
        parameters[:stream] = provider_stream if prompt.options[:stream] || config["stream"]
        chat_response(@client.chat(parameters: parameters))
      end

      def responses_prompt(parameters: prompt_parameters)
        parameters[:stream] = provider_stream if prompt.options[:stream] || config["stream"]
        responses_response(@client.responses.create(parameters: parameters))
      end

      def responses_response(response)
        return @response if prompt.options[:stream]
        
        # Handle responses API format which differs from chat API
        output = response.dig("output", 0)
        
        if output.nil?
          raise GenerationProviderError, "Invalid response format from responses API"
        end

        # Extract content based on output type
        content = case output["type"]
        when "message"
          # For message type outputs, extract content array
          content_items = output.dig("content") || []
          if content_items.empty?
            ""
          elsif content_items.length == 1 && content_items[0]["type"] == "text"
            content_items[0]["text"]
          else
            # Multiple content items or non-text content - keep as array
            content_items
          end
        when "function_call"
          # Function call - this will be handled as action_requested
          output["name"] || ""
        else
          # Fallback for other types
          output["content"] || output.to_s
        end

        # Handle structured outputs by parsing JSON content if needed
        if has_structured_output? && content.is_a?(String) && content.strip.start_with?("{", "[")
          begin
            parsed_content = JSON.parse(content, symbolize_names: true)
            content = parsed_content
          rescue JSON::ParserError
            # If JSON parsing fails, leave content as string for debugging
          end
        end

        # Determine if this is an action/tool call
        action_requested = output["type"] == "function_call" || output.key?("name")
        raw_actions = action_requested ? [output] : []
        requested_actions = action_requested ? [handle_responses_action(output)].compact : []

        message = ActiveAgent::ActionPrompt::Message.new(
          generation_id: response["id"],
          content: content,
          role: :assistant,
          action_requested: action_requested,
          raw_actions: raw_actions,
          requested_actions: requested_actions
        )

        update_context(prompt: prompt, message: message, response: response)

        @response = ActiveAgent::GenerationProvider::Response.new(prompt: prompt, message: message, raw_response: response)
      end

      def handle_responses_action(output)
        return nil unless output["name"]
        
        ActiveAgent::ActionPrompt::Action.new(
          id: output["id"] || SecureRandom.uuid,
          name: output["name"],
          params: output["parameters"] || output["arguments"] || {}
        )
      end

      def embeddings_parameters(input: prompt.message.content, model: "text-embedding-3-large")
        {
          model: model,
          input: input
        }
      end

      def embeddings_response(response)
        message = ActiveAgent::ActionPrompt::Message.new(content: response.dig("data", 0, "embedding"), role: "assistant")

        @response = ActiveAgent::GenerationProvider::Response.new(prompt: prompt, message: message, raw_response: response)
      end

      def embeddings_prompt(parameters:)
        embeddings_response(@client.embeddings(parameters: embeddings_parameters))
      end
    end
  end
end
