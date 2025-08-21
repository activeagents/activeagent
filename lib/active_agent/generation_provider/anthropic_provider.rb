# lib/active_agent/generation_provider/anthropic_provider.rb

begin
  gem "ruby-anthropic", "~> 0.4.2"
  require "anthropic"
rescue LoadError
  raise LoadError, "The 'ruby-anthropic' gem is required for AnthropicProvider. Please add it to your Gemfile and run `bundle install`."
end

require "active_agent/action_prompt/action"
require_relative "base"
require_relative "response"
require_relative "stream_processing"
require_relative "message_formatting"
require_relative "tool_management"

module ActiveAgent
  module GenerationProvider
    class AnthropicProvider < Base
      include StreamProcessing
      include MessageFormatting
      include ToolManagement
      def initialize(config)
        super
        @access_token ||= config["api_key"] || config["access_token"] || Anthropic.configuration.access_token || ENV["ANTHROPIC_ACCESS_TOKEN"]
        @extra_headers = config["extra_headers"] || {}
        @client = Anthropic::Client.new(access_token: @access_token, extra_headers: @extra_headers)
      end

      def generate(prompt)
        @prompt = prompt

        with_error_handling do
          chat_prompt(parameters: prompt_parameters)
        end
      end

      def chat_prompt(parameters: prompt_parameters)
        if prompt.options[:stream] || config["stream"]
          parameters[:stream] = provider_stream
          @streaming_request_params = parameters
        end

        chat_response(@client.messages(parameters: parameters), parameters)
      end

      protected

      # Override from StreamProcessing module for Anthropic-specific streaming
      def process_stream_chunk(chunk, message, agent_stream)
        if new_content = chunk.dig(:delta, :text)
          message.content += new_content
          agent_stream&.call(message, new_content, false, prompt.action_name)
        end

        if chunk[:type] == "message_stop"
          finalize_stream(message, agent_stream)
        end
      end

      # Override from ParameterBuilder to handle Anthropic-specific requirements
      def build_provider_parameters
        # Anthropic requires system message separately and no system role in messages
        filtered_messages = @prompt.messages.reject { |m| m.role == :system }
        system_message = @prompt.messages.find { |m| m.role == :system }

        params = {
          system: system_message&.content || @prompt.options[:instructions]
        }

        # Override messages to use filtered version
        @filtered_messages = filtered_messages

        params
      end

      def build_base_parameters
        super.tap do |params|
          # Use filtered messages if available (set by build_provider_parameters)
          params[:messages] = provider_messages(@filtered_messages || @prompt.messages)
          # Anthropic requires max_tokens
          params[:max_tokens] ||= 4096
        end
      end

      # Override from ToolManagement for Anthropic-specific tool format
      def format_single_tool(tool)
        {
          name: tool["name"] || tool.dig("function", "name") || tool[:name] || tool.dig(:function, :name),
          description: tool["description"] || tool.dig("function", "description") || tool[:description] || tool.dig(:function, :description),
          input_schema: tool["parameters"] || tool.dig("function", "parameters") || tool[:parameters] || tool.dig(:function, :parameters)
        }
      end

      # Override from MessageFormatting for Anthropic-specific message format
      def format_content(message)
        # Anthropic requires content as an array
        if message.content_type == "image_url"
          [ format_image_content(message).first ]
        else
          [ { type: "text", text: message.content } ]
        end
      end

      def format_image_content(message)
        [ {
          type: "image",
          source: {
            type: "url",
            url: message.content
          }
        } ]
      end

      # Override from MessageFormatting for Anthropic role mapping
      def convert_role(role)
        case role.to_s
        when "system" then "system"
        when "user" then "user"
        when "assistant" then "assistant"
        when "tool", "function" then "assistant"
        else "user"
        end
      end

      def chat_response(response, request_params = nil)
        return @response if prompt.options[:stream]

        content = response["content"].first["text"]

        message = ActiveAgent::ActionPrompt::Message.new(
          content: content,
          role: "assistant",
          action_requested: response["stop_reason"] == "tool_use",
          requested_actions: handle_actions(response["content"].map { |c| c if c["type"] == "tool_use" }.reject { |m| m.blank? }.to_a),
        )

        update_context(prompt: prompt, message: message, response: response)

        @response = ActiveAgent::GenerationProvider::Response.new(
          prompt: prompt,
          message: message,
          raw_response: response,
          raw_request: request_params
        )
      end

      # Override from ToolManagement for Anthropic-specific tool parsing
      def parse_tool_call(tool_use)
        return nil unless tool_use

        ActiveAgent::ActionPrompt::Action.new(
          id: tool_use[:id],
          name: tool_use[:name],
          params: tool_use[:input]
        )
      end

      private
    end
  end
end
