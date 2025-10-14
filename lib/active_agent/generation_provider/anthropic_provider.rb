# lib/active_agent/generation_provider/anthropic_provider.rb

require_relative "_base_provider"

require_gem!(:anthropic, __FILE__)

require_relative "anthropic/options"

module ActiveAgent
  module GenerationProvider
    class AnthropicProvider < BaseProvider
      include StreamProcessing
      include MessageFormatting
      include ToolManagement

      # @return [Anthropic::Client]
      def client
        ::Anthropic::Client.new(options.client_options)
      end

      def generate(prompt)
        with_error_handling do
          prompt_with_chat(parameters: generate_prompt_parameters(prompt))
        end
      end

      def prompt_with_chat(parameters)
        if prompt.options[:stream] || config["stream"]
          parameters[:stream] = provider_stream
          @streaming_request_params = parameters
        end

        chat_response(client.messages(parameters: parameters), parameters)
      end

      protected

      # Override from ParameterBuilder to handle Anthropic-specific requirements
      # Anthropic requires system message separately and no system role in messages
      def generate_prompt_parameters_messages(prompt)
        system_messages, action_messages = prompt.messages.partition { |m| m.role == :system }

        fail "Unexpected Extra System Messages" if system_messages.count > 1

        {
          system:   provider_messages(system_messages.first&.content || prompt.options[:instructions]),
          messages: provider_messages(action_messages)
        }
      end

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
          content_type: prompt.output_schema.present? ? "application/json" : "text/plain",
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
