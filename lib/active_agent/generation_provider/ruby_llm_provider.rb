# lib/active_agent/generation_provider/ruby_llm_provider.rb

begin
  gem "ruby_llm", ">= 0.1.0"
  require "ruby_llm"
rescue LoadError
  raise LoadError, "The 'ruby_llm >= 0.1.0' gem is required for RubyLLMProvider. Please add it to your Gemfile and run `bundle install`."
end

require "active_agent/action_prompt/action"
require_relative "base"
require_relative "response"
require_relative "stream_processing"
require_relative "message_formatting"
require_relative "tool_management"

module ActiveAgent
  module GenerationProvider
    class RubyLLMProvider < Base
      include StreamProcessing
      include MessageFormatting
      include ToolManagement

      def initialize(config)
        super
        
        # Configure RubyLLM with provided credentials
        configure_ruby_llm(config)
        
        # Initialize the chat client
        @client = RubyLLM.chat
        @model_name = config["model"] || "gpt-4o-mini"
        
        # Store flag for image generation capability
        @enable_image_generation = config["enable_image_generation"]
      end

      def generate(prompt)
        @prompt = prompt

        with_error_handling do
          chat_prompt(parameters: prompt_parameters)
        end
      end

      def embed(prompt)
        @prompt = prompt

        with_error_handling do
          embeddings_prompt(parameters: embeddings_parameters)
        end
      end

      protected

      # Override from StreamProcessing module for RubyLLM-specific streaming
      def process_stream_chunk(chunk, message, agent_stream)
        # RubyLLM streaming format handling
        if chunk.is_a?(String)
          # Direct string content from streaming
          message.content += chunk
          agent_stream&.call(message, chunk, false, prompt.action_name)
        elsif chunk.is_a?(Hash)
          # Structured response chunk
          if new_content = chunk["content"] || chunk[:content]
            message.generation_id = chunk["id"] || chunk[:id] if chunk["id"] || chunk[:id]
            message.content += new_content
            agent_stream&.call(message, new_content, false, prompt.action_name)
          elsif chunk["tool_calls"] || chunk[:tool_calls]
            handle_streaming_tool_calls(chunk, message)
          end

          if chunk["finish_reason"] || chunk[:finish_reason]
            finalize_stream(message, agent_stream)
          end
        end
      end

      # Override from MessageFormatting for RubyLLM image format
      def format_image_content(message)
        # RubyLLM supports direct file paths or URLs
        [{
          type: "image",
          content: message.content
        }]
      end

      private

      def configure_ruby_llm(config)
        RubyLLM.configure do |ruby_config|
          # Configure API keys for different providers
          ruby_config.openai_api_key = config["openai_api_key"] || ENV["OPENAI_API_KEY"] if config["openai_api_key"] || ENV["OPENAI_API_KEY"]
          
          # RubyLLM may not support all these configuration options yet
          # We'll add them conditionally as the gem evolves
          if ruby_config.respond_to?(:anthropic_api_key=)
            ruby_config.anthropic_api_key = config["anthropic_api_key"] || ENV["ANTHROPIC_API_KEY"] if config["anthropic_api_key"] || ENV["ANTHROPIC_API_KEY"]
          end
          
          if ruby_config.respond_to?(:gemini_api_key=)
            ruby_config.gemini_api_key = config["gemini_api_key"] || ENV["GEMINI_API_KEY"] if config["gemini_api_key"] || ENV["GEMINI_API_KEY"]
          end
          
          # These configuration options may not be available yet
          if ruby_config.respond_to?(:default_provider=)
            ruby_config.default_provider = config["default_provider"].to_sym if config["default_provider"]
          end
          
          if ruby_config.respond_to?(:timeout=)
            ruby_config.timeout = config["timeout"] if config["timeout"]
          end
          
          if ruby_config.respond_to?(:max_retries=)
            ruby_config.max_retries = config["max_retries"] if config["max_retries"]
          end
        end
      end

      def chat_prompt(parameters:)
        if prompt.options[:stream] || config["stream"]
          parameters[:stream] = provider_stream
          @streaming_request_params = parameters
        end

        chat_response(perform_chat_request(parameters), parameters)
      end

      def perform_chat_request(parameters)
        # Extract messages and options
        messages = parameters[:messages]
        options = parameters.except(:messages)
        
        # RubyLLM's chat client handles messages differently
        # We need to add messages to the client's context first
        if messages.is_a?(Array) && messages.any?
          # Clear any existing messages
          @client.reset_messages!
          
          # Add each message to the context
          messages.each do |msg|
            if msg.is_a?(Hash)
              role = msg[:role].to_s
              content = msg[:content]
              
              # RubyLLM uses add_message for context
              case role
              when "system"
                @client.with_instructions(content)
              when "assistant"
                @client.add_message(role: "assistant", content: content)
              when "user"
                @client.add_message(role: "user", content: content)
              when "tool"
                @client.add_message(role: "tool", content: content)
              end
            else
              # Default to user message
              @client.add_message(role: "user", content: msg)
            end
          end
          
          # Get the last user message for the ask call
          last_message = messages.last
          content = last_message.is_a?(Hash) ? last_message[:content] : last_message
        else
          content = ""
        end
        
        # Apply tools if provided
        if parameters[:tools].present?
          @client = @client.with_tools(parameters[:tools])
        end
        
        # Apply other parameters
        if parameters[:temperature]
          @client = @client.with_temperature(parameters[:temperature])
        end
        
        if parameters[:model]
          @client = @client.with_model(parameters[:model])
        end
        
        # Execute the chat request
        @client.ask(content, **options.except(:tools, :temperature, :model))
      end

      def chat_response(response, request_params = nil)
        return @response if prompt.options[:stream]

        # Handle RubyLLM response format
        message = parse_ruby_llm_response(response)
        
        update_context(prompt: prompt, message: message, response: response)

        @response = ActiveAgent::GenerationProvider::Response.new(
          prompt: prompt,
          message: message,
          raw_response: response,
          raw_request: request_params
        )
      end

      def parse_ruby_llm_response(response)
        # RubyLLM returns a simplified response format
        content = if response.is_a?(String)
          response
        elsif response.is_a?(Hash)
          response["content"] || response[:content] || response["text"] || response[:text]
        else
          response.to_s
        end

        # Check for tool calls
        tool_calls = extract_tool_calls(response) if response.is_a?(Hash)
        
        ActiveAgent::ActionPrompt::Message.new(
          generation_id: response.is_a?(Hash) ? (response["id"] || response[:id]) : nil,
          content: content,
          role: :assistant,
          action_requested: tool_calls.present?,
          raw_actions: tool_calls || [],
          requested_actions: handle_actions(tool_calls),
          content_type: prompt.output_schema.present? ? "application/json" : "text/plain"
        )
      end

      def extract_tool_calls(response)
        response["tool_calls"] || response[:tool_calls] || response["tools"] || response[:tools]
      end

      def handle_streaming_tool_calls(chunk, message)
        tool_calls = chunk["tool_calls"] || chunk[:tool_calls]
        if tool_calls
          message = parse_ruby_llm_response(chunk)
          prompt.messages << message
          @response = ActiveAgent::GenerationProvider::Response.new(
            prompt: prompt,
            message: message,
            raw_response: chunk,
            raw_request: @streaming_request_params
          )
        end
      end

      def embeddings_prompt(parameters:)
        response = RubyLLM.embed(parameters[:input], model: parameters[:model])
        embeddings_response(response, parameters)
      end

      def embeddings_response(response, request_params = nil)
        # Extract embedding from RubyLLM response
        embedding = if response.is_a?(Array)
          response
        elsif response.is_a?(Hash)
          response["embedding"] || response[:embedding] || response["data"] || response[:data]
        else
          response
        end
        
        message = ActiveAgent::ActionPrompt::Message.new(
          content: embedding,
          role: :assistant,
          content_type: "application/json"
        )

        @response = ActiveAgent::GenerationProvider::Response.new(
          prompt: prompt,
          message: message,
          raw_response: response,
          raw_request: request_params
        )
      end

      def embeddings_parameters
        {
          model: @prompt.options[:embedding_model] || @config["embedding_model"] || "text-embedding-3-small",
          input: @prompt.message.content
        }
      end

      # Override from ParameterBuilder if RubyLLM needs specific parameters
      def build_provider_parameters
        params = {}
        
        # Add provider selection if specified
        if @prompt.options[:provider]
          params[:provider] = @prompt.options[:provider].to_sym
        elsif @config["default_provider"]
          params[:provider] = @config["default_provider"].to_sym
        end
        
        # Add RubyLLM-specific features
        if @prompt.options[:with_images] && @prompt.options[:with_images].any?
          params[:with] = @prompt.options[:with_images]
        end
        
        # Add structured output schema if present
        if @prompt.output_schema.present?
          params[:schema] = @prompt.output_schema
        end
        
        params
      end

      # Additional method for image generation if enabled
      def generate_image(prompt_text, options = {})
        return unless @enable_image_generation
        
        RubyLLM.paint(prompt_text, **options)
      end
    end
  end
end