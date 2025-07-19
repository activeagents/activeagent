begin
  gem "ruby-openai", "~> 8.1.0"
  require "openai"
rescue LoadError
  raise LoadError, "The 'ruby-openai' gem is required for OpenAIProvider. Please add it to your Gemfile and run `bundle install`."
end

require "active_agent/action_prompt/action"
require_relative "base"
require_relative "response"

module ActiveAgent
  module GenerationProvider
    class OpenAIProvider < Base
      def initialize(config)
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
        raise GenerationProviderError, e.message
      end

      def embed(prompt)
        @prompt = prompt

        embeddings_prompt(parameters: embeddings_parameters)
      rescue => e
        raise GenerationProviderError, e.message
      end

      private

      def provider_stream
        agent_stream = prompt.options[:stream]

        message = ActiveAgent::ActionPrompt::Message.new(content: "", role: :assistant)

        @response = ActiveAgent::GenerationProvider::Response.new(prompt:, message:)
        proc do |chunk, bytesize|
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

          agent_stream.call(message, nil, true) do |message|
            yield message, nil if block_given?
          end
        end
      end

      def prompt_parameters(model: @prompt.options[:model] || @model_name, messages: @prompt.messages, temperature: @config["temperature"] || 0.7, tools: @prompt.actions)
        {
          model: model,
          messages: provider_messages(messages),
          temperature: temperature,
          tools: tools.presence
        }
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
          provider_message
        end
      end

      def chat_response(response)
        return @response if prompt.options[:stream]
        message_json = response.dig("choices", 0, "message")
        message_json["id"] = response.dig("id") if message_json["id"].blank?
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

      def chat_prompt(parameters: prompt_parameters)
        parameters[:stream] = provider_stream if prompt.options[:stream] || config["stream"]
        chat_response(@client.chat(parameters: parameters))
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
