begin
  gem "ruby-openai", "~> 8.1.0"
  require "openai"
rescue LoadError
  raise LoadError, "The 'ruby-openai' gem is required for OpenAIProvider. Please add it to your Gemfile and run `bundle install`."
end

require "active_agent/action_prompt/action"
require_relative "base"
require_relative "response"
require_relative "openai_adapters/chat_completions_adapter"
require_relative "openai_adapters/responses_adapter"

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

        # Initialize adapters
        @chat_adapter = OpenAIAdapters::ChatCompletionsAdapter.new(@client, @config)
        @responses_adapter = OpenAIAdapters::ResponsesAdapter.new(@client, @config)
      end

      def generate(prompt)
        adapter = select_adapter(prompt)
        adapter.generate(prompt)
        @response = adapter.response
      end

      def embed(prompt)
        adapter = select_adapter(prompt)
        adapter.embed(prompt)
        @response = adapter.response
      end

      private

      def select_adapter(prompt)
        if @responses_adapter.supports?(prompt)
          @responses_adapter
        else
          @chat_adapter
        end
      end
    end
  end
end
