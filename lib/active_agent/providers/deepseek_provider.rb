require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "deepseek/_types"

module ActiveAgent
  module Providers
    # Provides access to DeepSeek's OpenAI-compatible API.
    #
    # Extends OpenAI's Chat provider, which DeepSeek follows for request shape,
    # response shape and tool calling. Thinking mode is off by default — see
    # {DeepSeek::Chat::Request} — because DeepSeek turns it on unless told
    # otherwise and charges for the reasoning whether or not the answer needs
    # it.
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
