require "openai"
require_relative "open_ai_provider"

module ActiveAgent
  module GenerationProvider
    class OpenRouterProvider < OpenAIProvider
      def initialize(config)
        @config = config
        @access_token ||= config["api_key"] || config["access_token"] || ENV["OPENROUTER_API_KEY"] || ENV["OPENROUTER_ACCESS_TOKEN"]
        @model_name = config["model"]
        @client = OpenAI::Client.new(uri_base: "https://openrouter.ai/api/v1", access_token: @access_token, log_errors: true)
      end

      def responses_response(response)
        response_html_to_error(response) if response_html?(response)

        super
      end

      def response_html?(response)
        response.is_a?(String) && response.start_with?('<!DOCTYPE html>')
      end

      def response_html_to_error(response)
        raise ProviderApiError.new(
          response_extract_html_title(response),
          provider_name: "OpenRouter",
          error_type: "html_error_response"
        )
      end

      # OpenRouter sometimes sends HTML responses for errors. This seems like the
      # least bad way to figure out the error message without rendering the page.
      #
      # HTML => "<title>Model Not Found | OpenRouter</title>" => "Model Not Found"
      def response_extract_html_title(response)
        response[/<title>.+ \| OpenRouter<\/title>/][7..-22]
      end
    end
  end
end
