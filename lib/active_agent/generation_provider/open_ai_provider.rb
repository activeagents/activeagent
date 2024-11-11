# lib/active_agent/generation_provider/open_ai_provider.rb

require_relative "base"
require "openai"
require "active_agent/generation_provider/response"

module ActiveAgent
  module GenerationProvider
    class OpenAIProvider < Base
      def initialize(config)
        super
        @api_key = config["api_key"]
        @model_name = config["model"] || "gpt-3.5-turbo"
        @client = OpenAI::Client.new(api_key: @api_key)
      end

      def generate(prompt)
        @prompt = prompt
        parameters = prompt_parameters.merge(model: @model_name)

        # parameters[:instructions] = prompt.instructions.content if prompt.instructions.present?

        parameters[:stream] = provider_stream if prompt.config[:stream] || config["stream"]

        response = @client.chat(parameters: parameters)
        handle_response(response)
      rescue => e
        raise GenerationProviderError, e.message
      end

      private

      def provider_stream
        # prompt.config[:stream] will define a proc found in prompt at runtime
        # config[:stream] will define a proc found in config stream would come from an Agent class's generate_with or stream_with method calls
        agent_stream = prompt.config[:stream] || config["stream"]
        proc do |chunk, bytesize|
          # Provider parsing logic here
          new_content = chunk.dig("choices", 0, "delta", "content")
          message = @prompt.messages.find { |message| message.response_number == chunk.dig("choices", 0, "index") }
          message.update(content: message.content + new_content) if new_content

          # Call the custom stream_proc if provided
          agent_stream.call(message) if agent_stream.respond_to?(:call)
        end
      end

      def handle_response(response)
        message_json = response.dig("choices", 0, "message")
        message = ActiveAgent::ActionPrompt::Message.new(
          content: message_json["content"],
          role: message_json["role"],
          action_reqested: message_json["function_call"],
          requested_actions: message_json["tool_calls"]
        )
        ActiveAgent::GenerationProvider::Response.new(message: message, raw_response: response)
      end
    end
  end
end
