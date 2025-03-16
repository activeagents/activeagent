# lib/active_agent/generation_provider/open_ai_provider.rb

require "openai"
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
        @client = OpenAI::Client.new(access_token: @api_key, log_errors: true)
      end

      def generate(prompt)
        @prompt = prompt

        chat_prompt(parameters: prompt_parameters)
      rescue => e
        raise GenerationProviderError, e.message
      end

      def chat_prompt(parameters: prompt_parameters)
        parameters[:stream] = provider_stream if prompt.options[:stream] || config["stream"]
        
        chat_response(@client.chat(parameters: parameters))
      end

      def embed(prompt)
        @prompt = prompt

        embeddings_prompt(parameters: embeddings_parameters)
      rescue => e
        raise GenerationProviderError, e.message  
      end

      def embeddings_parameters(input: prompt.message.content, model: "text-embedding-3-large")
        {
          model: model,
          input: input
        }
      end

      def embeddings_response(response)
        message = Message.new(content:response.dig("data", 0, "embedding"), role: "assistant")

        @response = ActiveAgent::GenerationProvider::Response.new(prompt: prompt, message: message, raw_response: response)
      end
      
      def embeddings_prompt(parameters: )
        embeddings_response(@client.embeddings(parameters: embeddings_parameters))
      end

      private

      def provider_stream
        # prompt.options[:stream] will define a proc found in prompt at runtime
        # config[:stream] will define a proc found in config. stream would come from an Agent class's generate_with or stream_with method calls
        agent_stream = prompt.options[:stream]
        message = ActiveAgent::ActionPrompt::Message.new(content: "", role: :assistant)
        @response = ActiveAgent::GenerationProvider::Response.new(prompt: prompt, message: ) 
        
        proc do |chunk, bytesize|
          if new_content = chunk.dig("choices", 0, "delta", "content")
            message.content += new_content
            agent_stream.call(message) if agent_stream.respond_to?(:call)
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
          provider_message {
            role: message.role, 
            tool_call_id: message.action_id.presence,
            content: message.content,
            type: message.content_type,
            charset: message.charset
        }.compact

        if content_type == "image_url"
          provider_message[:image_url] = { url: content }
        end        
        end
      end

      def chat_response(response)
        return @response if prompt.options[:stream]

        message_json = response.dig("choices", 0, "message")
        
        message = ActiveAgent::ActionPrompt::Message.new(
          content: message_json["content"],
          role: message_json["role"],
          action_requested: message_json["finish_reason"] == "tool_calls",
          requested_actions: handle_actions(message_json["tool_calls"])
        )
        update_context(prompt: prompt, message: message, response: response)

        @response = ActiveAgent::GenerationProvider::Response.new(prompt: prompt, message: message, raw_response: response)
      end

      def handle_actions(tool_calls)
        if tool_calls
          tool_calls.map do |tool_call|
            ActiveAgent::ActionPrompt::Action.new(
              id: tool_call["id"],
              name: tool_call.dig("function", "name"),
              params: JSON.parse(
                tool_call.dig("function", "arguments"),
                {symbolize_names: true}
              )
            )
          end
        end
      end
    end
  end
end
