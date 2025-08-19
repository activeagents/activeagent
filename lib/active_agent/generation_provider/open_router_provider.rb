require "openai"
require_relative "open_ai_provider"

module ActiveAgent
  module GenerationProvider
    class OpenRouterProvider < OpenAIProvider
      def initialize(config)
        @config = config
        @access_token = config["api_key"] || config["access_token"] ||
                       ENV["OPENROUTER_API_KEY"] || ENV["OPENROUTER_ACCESS_TOKEN"]
        @model_name = config["model"]

        # OpenRouter-specific configuration
        @app_name = config["app_name"] || default_app_name
        @site_url = config["site_url"] || default_site_url
        @enable_fallbacks = config["enable_fallbacks"] != false
        @fallback_models = config["fallback_models"] || []
        @transforms = config["transforms"] || []
        @provider_preferences = config["provider"] || {}
        @track_costs = config["track_costs"] != false
        @route = config["route"] || "fallback"

        # Data collection preference (allow, deny, or specific provider list)
        @data_collection = config["data_collection"] || @provider_preferences["data_collection"] || "allow"

        # Initialize OpenAI client with OpenRouter base URL
        @client = OpenAI::Client.new(
          uri_base: "https://openrouter.ai/api/v1",
          access_token: @access_token,
          log_errors: Rails.env.development?,
          default_headers: openrouter_headers
        )
      end

      def generate(prompt)
        @prompt = prompt

        with_error_handling do
          parameters = build_openrouter_parameters
          response = execute_with_fallback(parameters)
          process_openrouter_response(response)
        end
      rescue => e
        handle_openrouter_error(e)
      end

      protected

      def build_provider_parameters
        # Start with base OpenAI parameters
        params = super

        # Add OpenRouter-specific parameters
        add_openrouter_params(params)
      end

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

      def default_app_name
        if defined?(Rails) && Rails.application
          Rails.application.class.name.split("::").first
        else
          "ActiveAgent"
        end
      end

      def default_site_url
        # First check ActiveAgent config
        return config["default_url_options"]["host"] if config.dig("default_url_options", "host")

        # Then check Rails routes default_url_options
        if defined?(Rails) && Rails.application&.routes&.default_url_options&.any?
          host = Rails.application.routes.default_url_options[:host]
          port = Rails.application.routes.default_url_options[:port]
          protocol = Rails.application.routes.default_url_options[:protocol] || "https"

          if host
            url = "#{protocol}://#{host}"
            url += ":#{port}" if port && port != 80 && port != 443
            return url
          end
        end

        # Finally check ActionMailer config as fallback
        if defined?(Rails) && Rails.application&.config&.action_mailer&.default_url_options
          options = Rails.application.config.action_mailer.default_url_options
          host = options[:host]
          port = options[:port]
          protocol = options[:protocol] || "https"

          if host
            url = "#{protocol}://#{host}"
            url += ":#{port}" if port && port != 80 && port != 443
            return url
          end
        end

        nil
      end

      def openrouter_headers
        headers = {}
        headers["HTTP-Referer"] = @site_url if @site_url
        headers["X-Title"] = @app_name if @app_name
        headers
      end

      def build_openrouter_parameters
        parameters = prompt_parameters

        # Handle multiple models for fallback
        if @fallback_models.present?
          parameters[:models] = [ @model_name ] + @fallback_models
          parameters[:route] = @route
        end

        # Add transforms if specified
        parameters[:transforms] = @transforms if @transforms.present?

        # Add provider preferences (always include if we have data_collection or other settings)
        # Check both configured and runtime data_collection values
        runtime_data_collection = prompt&.options&.key?(:data_collection)
        if @provider_preferences.present? || @data_collection != "allow" || runtime_data_collection
          parameters[:provider] = build_provider_preferences
        end

        # Add plugins (e.g., for PDF processing)
        
        parameters[:plugins] = prompt.options[:plugins] if prompt.options[:plugins].present?
        parameters[:models] = prompt.options[:fallback_models] if prompt.options[:enable_fallbacks] && prompt.options[:fallback_models].present?
        parameters
      end

      def build_provider_preferences
        prefs = {}
        prefs[:order] = @provider_preferences["order"] if @provider_preferences["order"]
        prefs[:require_parameters] = @provider_preferences["require_parameters"] if @provider_preferences.key?("require_parameters")
        prefs[:allow_fallbacks] = @enable_fallbacks

        # Data collection can be:
        # - "allow" (default): Allow all providers to collect data
        # - "deny": Deny all providers from collecting data
        # - Array of provider names: Only allow these providers to collect data
        # Check prompt options first (runtime override), then fall back to configured value
        data_collection = prompt.options[:data_collection] if prompt&.options&.key?(:data_collection)
        data_collection ||= @data_collection
        prefs[:data_collection] = data_collection

        prefs.compact
      end

      def add_openrouter_params(params)
        # Add OpenRouter-specific routing parameters
        if @enable_fallbacks && @fallback_models.present?
          params[:models] = [ @model_name ] + @fallback_models
          params[:route] = @route
        end

        # Add transforms
        params[:transforms] = @transforms if @transforms.present?

        # Add provider configuration (always include if we have data_collection or other settings)
        # Check both configured and runtime data_collection values
        runtime_data_collection = prompt&.options&.key?(:data_collection)
        if @provider_preferences.present? || @data_collection != "allow" || runtime_data_collection
          params[:provider] = build_provider_preferences
        end

        # Add plugins (e.g., for PDF processing)
        if prompt.options[:plugins].present?
          params[:plugins] = prompt.options[:plugins]
        end

        params
      end

      def execute_with_fallback(parameters)
        parameters[:stream] = provider_stream if prompt.options[:stream] || config["stream"]

        response = @client.chat(parameters: parameters)
        # Log if fallback was used
        if response.respond_to?(:headers) && response.headers["x-model"] != @model_name
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
            fallback_used: response["model"] != @model_name
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
          fallback_used: headers["x-model"] != @model_name,
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
        model = response.dig("model") || @model_name

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
