require "active_agent/action_prompt/action"
require "active_agent/generation_provider/base"

module ActiveAgent
  module GenerationProvider
    module OpenAIAdapters
      class BaseAdapter
        attr_reader :client, :config, :prompt, :response

        def initialize(client, config)
          @client = client
          @config = config
        end

        def generate(prompt)
          @prompt = prompt
          perform_generation
        rescue => e
          error_message = e.respond_to?(:message) ? e.message : e.to_s
          raise ActiveAgent::GenerationProvider::Base::GenerationProviderError, error_message
        end

        def embed(prompt)
          @prompt = prompt
          perform_embedding
        rescue => e
          error_message = e.respond_to?(:message) ? e.message : e.to_s
          raise ActiveAgent::GenerationProvider::Base::GenerationProviderError, error_message
        end

        protected

        def perform_generation
          raise NotImplementedError, "Subclasses must implement #perform_generation"
        end

        def perform_embedding
          raise NotImplementedError, "Subclasses must implement #perform_embedding"
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

        def default_model
          @config["model"] || "gpt-4o-mini"
        end

        def temperature
          @prompt.options[:temperature] || @config["temperature"] || 0.7
        end

        def max_tokens
          @prompt.options[:max_tokens] || @config["max_tokens"]
        end

        def stream_enabled?
          @prompt.options[:stream] || @config["stream"]
        end
      end
    end
  end
end
