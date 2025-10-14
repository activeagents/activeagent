require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "open_router/options"

module ActiveAgent
  module GenerationProvider
    class OpenRouterProvider < OpenAI::ChatProvider
      def initialize(config)
        @track_costs = config.delete("track_costs") != false
        super
      end

      def generate(prompt)
        with_error_handling do
          parameters = build_openrouter_parameters
          response = execute_with_fallback(parameters)
          process_openrouter_response(response)
        end
      rescue => e
        handle_openrouter_error(e)
      end

      protected

      def format_content_item(item)
        # Handle OpenRouter-specific content formats
        if item.is_a?(Hash)
          case item[:type] || item["type"]
          when "file"
            # Convert file type to image_url for OpenRouter PDF support
            file_data = item.dig(:file, :file_data) || item.dig("file", "file_data")
            if file_data
              {
                type: "image_url",
                image_url: {
                  url: file_data
                }
              }
            else
              item
            end
          else
            # Use default formatting for other types
            super
          end
        else
          super
        end
      end

      private

      def build_openrouter_parameters
        generate_prompt_parameters(prompt).deep_merge(options.prompt_parameters)
      end

      # TODO: Refactor out
      def build_provider_preferences
        provider_chat_parameters = options.provider_parameters || {}

        if prompt
          raw_prompt_options = prompt.options.deep_symbolize_keys.except(:service, :instructions, :plugins)
          prompt_chat_parameters = namespace::Options.new(**raw_prompt_options).provider_parameters || {}
          provider_chat_parameters.deep_merge(prompt_chat_parameters)
        else
          provider_chat_parameters
        end
      end

      def execute_with_fallback(parameters)
        parameters[:stream] = provider_stream if prompt.options[:stream] || config["stream"]

        response = client.chat(parameters: parameters)
        # Log if fallback was used
        if response.respond_to?(:headers) && response.headers["x-model"] != @options.model
          Rails.logger.info "[OpenRouter] Fallback model used: #{response.headers['x-model']}" if defined?(Rails)
        end

        response
      end

      def process_openrouter_response(response)
        # Process as normal OpenAI response first
        if prompt.options[:stream]
          return @response
        end

        # Extract standard response
        message_json = response.dig("choices", 0, "message")
        message_json["id"] = response.dig("id") if message_json && message_json["id"].blank?
        message = handle_message(message_json) if message_json

        update_context(prompt: prompt, message: message, response: response) if message
        # Create response with OpenRouter metadata
        @response = ActiveAgent::GenerationProvider::Response.new(
          prompt: prompt,
          message: message,
          raw_response: response
        )

        # OpenRouter includes provider and model info directly in the response body
        if response["provider"] || response["model"]
          @response.metadata = {
            provider: response["provider"],
            model_used: response["model"],
            fallback_used: response["model"] != @options.model
          }.compact
        end

        # Track costs if enabled
        track_usage(response) if @track_costs && response["usage"]

        @response
      end

      def add_openrouter_metadata(response, headers)
        return unless response.respond_to?(:metadata=)

        response.metadata = {
          provider: headers["x-provider"],
          model_used: headers["x-model"],
          trace_id: headers["x-trace-id"],
          fallback_used: headers["x-model"] != @options.model,
          ratelimit: {
            requests_limit: headers["x-ratelimit-requests-limit"],
            requests_remaining: headers["x-ratelimit-requests-remaining"],
            requests_reset: headers["x-ratelimit-requests-reset"],
            tokens_limit: headers["x-ratelimit-tokens-limit"],
            tokens_remaining: headers["x-ratelimit-tokens-remaining"],
            tokens_reset: headers["x-ratelimit-tokens-reset"]
          }.compact
        }.compact
      end

      def track_usage(response)
        return nil unless @track_costs
        return nil unless response["usage"]

        usage = response["usage"]
        model = response.dig("model") || @options.model

        # Calculate costs (simplified - would need actual pricing data)
        cost_info = {
          model: model,
          prompt_tokens: usage["prompt_tokens"],
          completion_tokens: usage["completion_tokens"],
          total_tokens: usage["total_tokens"]
        }

        # Log usage information
        if defined?(Rails)
          Rails.logger.info "[OpenRouter] Usage: #{cost_info.to_json}"

          # Store in cache if available
          if Rails.cache
            cache_key = "openrouter:usage:#{Date.current}"
            Rails.cache.increment("#{cache_key}:tokens", usage["total_tokens"])
            Rails.cache.increment("#{cache_key}:requests")
          end
        end

        cost_info
      end

      def handle_openrouter_error(error)
        error_message = error.message || error.to_s

        case error_message
        when /rate limit/i
          handle_rate_limit_error(error)
        when /insufficient credits|payment required/i
          handle_insufficient_credits(error)
        when /no available provider/i
          handle_no_provider_error(error)
        when /timeout/i
          handle_timeout_error(error)
        else
          # Fall back to parent error handling
          raise GenerationProviderError, error, error.backtrace
        end
      end

      def handle_rate_limit_error(error)
        Rails.logger.error "[OpenRouter] Rate limit exceeded: #{error.message}" if defined?(Rails)
        raise GenerationProviderError, "OpenRouter rate limit exceeded. Please retry later."
      end

      def handle_insufficient_credits(error)
        Rails.logger.error "[OpenRouter] Insufficient credits: #{error.message}" if defined?(Rails)
        raise GenerationProviderError, "OpenRouter account has insufficient credits."
      end

      def handle_no_provider_error(error)
        Rails.logger.error "[OpenRouter] No available provider: #{error.message}" if defined?(Rails)
        raise GenerationProviderError, "No available provider for the requested model."
      end

      def handle_timeout_error(error)
        Rails.logger.error "[OpenRouter] Request timeout: #{error.message}" if defined?(Rails)
        raise GenerationProviderError, "OpenRouter request timed out."
      end
    end
  end
end
