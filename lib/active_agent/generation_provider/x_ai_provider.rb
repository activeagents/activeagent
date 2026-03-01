# frozen_string_literal: true

begin
  gem "ruby-openai", ">= 8.1.0"
  require "openai"
rescue LoadError
  raise LoadError, "The 'ruby-openai >= 8.1.0' gem is required for XAIProvider. Please add it to your Gemfile and run `bundle install`."
end

require "active_agent/action_prompt/action"
require_relative "base"
require_relative "response"
require_relative "stream_processing"
require_relative "message_formatting"
require_relative "tool_management"

module ActiveAgent
  module GenerationProvider
    # XAI (Grok) Generation Provider
    # Uses OpenAI-compatible API format with xAI's endpoint
    class XAIProvider < Base
      include StreamProcessing
      include MessageFormatting
      include ToolManagement

      XAI_API_HOST = "https://api.x.ai"

      def initialize(config)
        super
        # Support both api_key and access_token for backwards compatibility
        @access_token = config["api_key"] || config["access_token"] || ENV["XAI_API_KEY"] || ENV["GROK_API_KEY"]

        unless @access_token
          raise ArgumentError, "XAI API key is required. Set it in config as 'api_key', 'access_token', or via XAI_API_KEY/GROK_API_KEY environment variable."
        end

        # xAI uses OpenAI-compatible client with custom endpoint
        @client = OpenAI::Client.new(
          access_token: @access_token,
          uri_base: config["host"] || XAI_API_HOST,
          log_errors: Rails.env.development?
        )

        # Default to grok-2-latest but allow configuration
        @model_name = config["model"] || "grok-2-latest"
      end

      def generate(prompt)
        @prompt = prompt

        with_error_handling do
          chat_prompt(parameters: prompt_parameters)
        end
      end

      def embed(prompt)
        # xAI doesn't currently provide embedding models
        raise NotImplementedError, "xAI does not currently support embeddings. Use a different provider for embedding tasks."
      end

      protected

      # Override from StreamProcessing module - uses OpenAI format
      def process_stream_chunk(chunk, message, agent_stream)
        new_content = chunk.dig("choices", 0, "delta", "content")
        if new_content && !new_content.blank?
          message.generation_id = chunk.dig("id")
          message.content += new_content
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

      # Override from MessageFormatting module to handle image format (if xAI adds vision support)
      def format_image_content(message)
        [ {
          type: "image_url",
          image_url: { url: message.content }
        } ]
      end

      private

      # Override from ParameterBuilder to add xAI-specific parameters if needed
      def build_provider_parameters
        params = {}

        # Add any xAI-specific parameters here
        # For now, xAI follows OpenAI's format closely

        params
      end

      def chat_response(response, request_params = nil)
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

      def chat_prompt(parameters: prompt_parameters)
        if prompt.options[:stream] || config["stream"]
          parameters[:stream] = provider_stream
          @streaming_request_params = parameters
        end
        chat_response(@client.chat(parameters: parameters), parameters)
      end
    end
  end
end
