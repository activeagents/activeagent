# lib/active_agent/generation_provider/anthropic_provider.rb

require "anthropic"
require "active_agent/action_prompt/action"
require_relative "base"
require_relative "response"

module ActiveAgent
  module GenerationProvider
    class AnthropicProvider < Base
      def initialize(config)
        super
        @api_key = config["api_key"]
        @model_name = config["model"] || "claude-3-5-sonnet-20240620"
        @client = Anthropic::Client.new(access_token: @api_key)
      end

      def generate(prompt)
        @prompt = prompt

        chat_prompt(parameters: prompt_parameters)
      rescue => e
        error_message = e.respond_to?(:message) ? e.message : e.to_s
        raise GenerationProviderError, error_message
      end

      def chat_prompt(parameters: prompt_parameters)
        parameters[:stream] = provider_stream if prompt.options[:stream] || config["stream"]

        chat_response(@client.messages(parameters))
      end

      private

      def provider_stream
        agent_stream = prompt.options[:stream]
        message = ActiveAgent::ActionPrompt::Message.new(content: "", role: :assistant)
        @response = ActiveAgent::GenerationProvider::Response.new(prompt: prompt, message:)

        proc do |chunk|
          if new_content = chunk.dig(:delta, :text)
            message.content += new_content
            agent_stream.call(message, nil, false, prompt.action_name) if agent_stream.respond_to?(:call)
          end
        end
      end

      def prompt_parameters(model: @prompt.options[:model] || @model_name, messages: @prompt.messages, temperature: @prompt.options[:temperature] || @config["temperature"] || 0.7, tools: @prompt.actions)
        params = {
          model: model,
          messages: provider_messages(messages),
          temperature: temperature,
          max_tokens: @prompt.options[:max_tokens] || @config["max_tokens"] || 4096
        }

        if tools&.present?
          params[:tools] = format_tools(tools)
        end

        params
      end

      def format_tools(tools)
        tools.map do |tool|
          {
            name: tool[:name] || tool[:function][:name],
            description: tool[:description],
            input_schema: tool[:parameters]
          }
        end
      end

      def provider_messages(messages)
        messages.map do |message|
          provider_message = {
            role: convert_role(message.role),
            content: []
          }

          provider_message[:content] << if message.content_type == "image_url"
            {
              type: "image",
              source: {
                type: "url",
                url: message.content
              }
            }
          else
            {
              type: "text",
              text: message.content
            }
          end

          provider_message
        end
      end

      def convert_role(role)
        case role.to_s
        when "system" then "system"
        when "user" then "user"
        when "assistant" then "assistant"
        when "tool", "function" then "assistant"
        else "user"
        end
      end

      def chat_response(response)
        return @response if prompt.options[:stream]

        content = response.content.first[:text]

        message = ActiveAgent::ActionPrompt::Message.new(
          content: content,
          role: "assistant",
          action_requested: response.stop_reason == "tool_use",
          requested_actions: handle_actions(response.tool_use)
        )

        update_context(prompt: prompt, message: message, response: response)

        @response = ActiveAgent::GenerationProvider::Response.new(
          prompt: prompt,
          message: message,
          raw_response: response
        )
      end

      def handle_actions(tool_uses)
        return unless tool_uses&.present?

        tool_uses.map do |tool_use|
          ActiveAgent::ActionPrompt::Action.new(
            id: tool_use[:id],
            name: tool_use[:name],
            params: tool_use[:input]
          )
        end
      end
    end
  end
end
