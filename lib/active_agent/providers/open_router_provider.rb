require_relative "_base_provider"

require_gem!(:openai, __FILE__)

require_relative "open_ai_provider"
require_relative "open_router/options"
require_relative "open_router/request"

module ActiveAgent
  module Providers
    # Provider implementation for OpenRouter's multi-model API.
    #
    # Extends OpenAI::ChatProvider to work with OpenRouter's OpenAI-compatible API.
    # Provides access to multiple AI models through a single interface with features
    # like model fallbacks, cost tracking, and provider metadata.
    #
    # @see OpenAI::ChatProvider
    # @see https://openrouter.ai/docs
    class OpenRouterProvider < OpenAI::ChatProvider
      def service_name         = "OpenRouter"
      def options_klass        = namespace::Options
      def prompt_request_klass = namespace::Request

      # def initialize(config)
      #   @track_costs = config.delete("track_costs") != false
      #   super
      # end

      #   retriable do
      #     resolve_prompt
      #   end
      #   rescue StandardError => exception
      #     handle_openrouter_error(exception)
      # end

      protected

      # def resolve_prompt
      #   response = client.chat(parameters: parameters)
      #   # Log if fallback was used
      #   if response.respond_to?(:headers) && response.headers["x-model"] != @options.model
      #     Rails.logger.info "[OpenRouter] Fallback model used: #{response.headers['x-model']}" if defined?(Rails)
      #   end

      #   response
      # end

      # def process_openrouter_response(response)
      #   # OpenRouter includes provider and model info directly in the response body
      #   if response["provider"] || response["model"]
      #     @response.metadata = {
      #       provider: response["provider"],
      #       model_used: response["model"],
      #       fallback_used: response["model"] != @options.model
      #     }.compact
      #   end

      #   # Track costs if enabled
      #   track_usage(response) if @track_costs && response["usage"]

      #   @response
      # end

      # def add_openrouter_metadata(response, headers)
      #   return unless response.respond_to?(:metadata=)

      #   response.metadata = {
      #     provider: headers["x-provider"],
      #     model_used: headers["x-model"],
      #     trace_id: headers["x-trace-id"],
      #     fallback_used: headers["x-model"] != @options.model,
      #     ratelimit: {
      #       requests_limit: headers["x-ratelimit-requests-limit"],
      #       requests_remaining: headers["x-ratelimit-requests-remaining"],
      #       requests_reset: headers["x-ratelimit-requests-reset"],
      #       tokens_limit: headers["x-ratelimit-tokens-limit"],
      #       tokens_remaining: headers["x-ratelimit-tokens-remaining"],
      #       tokens_reset: headers["x-ratelimit-tokens-reset"]
      #     }.compact
      #   }.compact
      # end

      # def track_usage(response)
      #   return nil unless @track_costs
      #   return nil unless response["usage"]

      #   usage = response["usage"]
      #   model = response.dig("model") || @options.model

      #   # Calculate costs (simplified - would need actual pricing data)
      #   cost_info = {
      #     model: model,
      #     prompt_tokens: usage["prompt_tokens"],
      #     completion_tokens: usage["completion_tokens"],
      #     total_tokens: usage["total_tokens"]
      #   }

      #   # Log usage information
      #   if defined?(Rails)
      #     Rails.logger.info "[OpenRouter] Usage: #{cost_info.to_json}"

      #     # Store in cache if available
      #     if Rails.cache
      #       cache_key = "openrouter:usage:#{Date.current}"
      #       Rails.cache.increment("#{cache_key}:tokens", usage["total_tokens"])
      #       Rails.cache.increment("#{cache_key}:requests")
      #     end
      #   end

      #   cost_info
      # end

      # def handle_openrouter_error(error)
      #   error_message = error.message || error.to_s

      #   case error_message
      #   when /rate limit/i
      #     handle_rate_limit_error(error)
      #   when /insufficient credits|payment required/i
      #     handle_insufficient_credits(error)
      #   when /no available provider/i
      #     handle_no_provider_error(error)
      #   when /timeout/i
      #     handle_timeout_error(error)
      #   else
      #     # Fall back to parent error handling
      #     raise ProvidersError, error, error.backtrace
      #   end
      # end

      # def handle_rate_limit_error(error)
      #   Rails.logger.error "[OpenRouter] Rate limit exceeded: #{error.message}" if defined?(Rails)
      #   raise ProvidersError, "OpenRouter rate limit exceeded. Please retry later."
      # end

      # def handle_insufficient_credits(error)
      #   Rails.logger.error "[OpenRouter] Insufficient credits: #{error.message}" if defined?(Rails)
      #   raise ProvidersError, "OpenRouter account has insufficient credits."
      # end

      # def handle_no_provider_error(error)
      #   Rails.logger.error "[OpenRouter] No available provider: #{error.message}" if defined?(Rails)
      #   raise ProvidersError, "No available provider for the requested model."
      # end

      # def handle_timeout_error(error)
      #   Rails.logger.error "[OpenRouter] Request timeout: #{error.message}" if defined?(Rails)
      #   raise ProvidersError, "OpenRouter request timed out."
      # end
    end
  end
end
