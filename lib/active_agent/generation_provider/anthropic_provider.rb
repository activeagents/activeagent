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

module ActiveAgent
  module GenerationProvider
    class AnthropicProvider < Base
      def initialize(config)
        super
        @access_token ||= config["api_key"] || config["access_token"] || Anthropic.configuration.access_token || ENV["ANTHROPIC_ACCESS_TOKEN"]
        @extra_headers = config["extra_headers"] || {}
        @client = Anthropic::Client.new(access_token: @access_token, extra_headers:@extra_headers)
      end

      def generate(prompt)
        @prompt = prompt

        chat_prompt(parameters: prompt_parameters)
      rescue => e
        error_message = e.respond_to?(:message) ? e.message : e.to_s
        if e.respond_to?(:response)
          error_message += " - #{e.response[:body]["error"]["message"]}"
        end
        raise GenerationProviderError, error_message
      end

      def chat_prompt(parameters: prompt_parameters)
        parameters[:stream] = provider_stream if prompt.options[:stream] || config["stream"]

        chat_response(@client.messages(parameters: parameters))
      end

      private

      def provider_stream
        agent_stream = prompt.options[:stream]
        message = ActiveAgent::ActionPrompt::Message.new(content: "", role: :assistant)
        @response = ActiveAgent::GenerationProvider::Response.new(prompt: prompt)

        proc do |chunk|
          if new_content = chunk.dig(:delta, :text)
            message.content += new_content
            agent_stream.call(message, nil, false, prompt.action_name) if agent_stream.respond_to?(:call)
          end
        end
      end

      def prompt_parameters(model: @prompt.options[:model] || @model_name, messages: @prompt.messages, temperature: @prompt.options[:temperature] || @config["temperature"] || 0.7, tools: @prompt.actions, mcp_servers: @prompt.mcp_servers)
        # fix for new Anthropic API that requires messages to be in a specific format without system role
        system_messages = messages.select { |m| m.role == :system }
        messages = messages.reject { |m| m.role == :system }
        params = {
          model: model,
          system: system_messages.last.content || @prompt.options[:instructions],
          messages: provider_messages(messages),
          temperature: temperature,
          mcp_servers: mcp_servers,
          max_tokens: @prompt.options[:max_tokens] || @config["max_tokens"] || 4096
        }

        if tools&.present?
          params[:tools] = format_tools(tools)
        end

        params
      end

      def format_tools(tools)
        tools.map do |tool|
          if tool["type"] == "function"
          {
            name: tool["name"] || tool["function"]["name"],
            description: tool["description"] || tool["function"]["description"],
            input_schema: tool["parameters"]  || tool["function"]["parameters"]
          }
          else
            {
              type: tool["type"],
              name: tool["name"],
              max_uses: tool["max_uses"]
            }
          end
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
              text: message.content.blank?? "do nothing" : message.content
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
          raw_response: response
        )
      end

      def handle_actions(tool_uses)
        return unless tool_uses&.present?

        tool_uses.map do |tool_use|
          ActiveAgent::ActionPrompt::Action.new(
            id: tool_use["id"],
            name: tool_use["name"],
            params: tool_use["input"]
          )
        end
      end
    end
  end
end
