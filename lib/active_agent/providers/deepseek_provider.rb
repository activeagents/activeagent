require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "deepseek/_types"

module ActiveAgent
  module Providers
    # Provides access to DeepSeek's OpenAI-compatible API.
    #
    # Extends OpenAI's Chat provider, which DeepSeek follows for request shape,
    # response shape and tool calling. Thinking mode is left to DeepSeek's own
    # default — see {DeepSeek::Chat::Request} — because the provider's API is the
    # authority on how it wants to be called.
    #
    # @example Configuration in active_agent.yml
    #   deepseek:
    #     service: "DeepSeek"
    #     api_key: <%= ENV["DEEPSEEK_API_KEY"] %>
    #
    # @example Usage
    #   class TicketAgent < ApplicationAgent
    #     generate_with :deepseek, model: "deepseek-flash"
    #   end
    #
    # @see OpenAI::ChatProvider
    # @see https://api-docs.deepseek.com
    class DeepSeekProvider < OpenAI::ChatProvider
      # @return [String]
      def self.service_name
        "DeepSeek"
      end

      # @return [Class]
      def self.options_klass
        namespace::Options
      end

      # @return [ActiveModel::Type::Value]
      def self.prompt_request_type
        namespace::Chat::RequestType.new
      end
    end
  end
end
