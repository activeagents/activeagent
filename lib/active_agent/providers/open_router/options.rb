# frozen_string_literal: true

require_relative "../open_ai/options"
require_relative "requests/response_format"
require_relative "requests/prediction"
require_relative "requests/provider_preferences"

module ActiveAgent
  module Providers
    module OpenRouter
      # Configuration options for OpenRouter provider
      #
      # Extends OpenAI::Options with OpenRouter-specific settings including
      # HTTP-Referer and X-Title headers for app identification and ranking.
      #
      # @example Basic configuration
      #   options = Options.new(
      #     api_key: 'sk-or-v1-...',
      #     app_name: 'MyApp',
      #     site_url: 'https://myapp.com'
      #   )
      #
      # @example Rails auto-configuration
      #   # Automatically resolves app_name from Rails.application
      #   # and site_url from routes.default_url_options
      #   options = Options.new(api_key: ENV['OPENROUTER_API_KEY'])
      #
      # @see https://openrouter.ai/docs/api-keys OpenRouter API Keys
      # @see https://openrouter.ai/docs/rankings OpenRouter App Rankings
      class Options < ActiveAgent::Providers::OpenAI::Options
        # @!attribute base_url
        #   @return [String] API endpoint (default: "https://openrouter.ai/api/v1")
        attribute :base_url, :string, as: "https://openrouter.ai/api/v1"

        # @!attribute app_name
        #   @return [String] application name for X-Title header (default: "ActiveAgent" or Rails app name)
        attribute :app_name, :string, fallback: "ActiveAgent"

        # @!attribute site_url
        #   @return [String] site URL for HTTP-Referer header (default: "https://activeagents.ai/" or Rails URL)
        attribute :site_url, :string, fallback: "https://activeagents.ai/"

        # Creates new OpenRouter options with auto-resolution
        #
        # Automatically resolves app_name from Rails application name and
        # site_url from Rails routes/ActionMailer default_url_options.
        #
        # @param kwargs [Hash] configuration options
        # @option kwargs [String] :api_key OpenRouter API key
        # @option kwargs [String] :app_name application name for rankings
        # @option kwargs [String] :site_url site URL for rankings
        # @return [Options]
        def initialize(kwargs = {})
          kwargs = kwargs.deep_symbolize_keys if kwargs.respond_to?(:deep_symbolize_keys)

          super(**deep_compact(kwargs.merge(
            app_name: kwargs[:app_name] || resolve_app_name(kwargs),
            site_url: kwargs[:site_url] || resolve_site_url(kwargs),
          )))
        end

        # Serializes options for API requests
        #
        # Excludes app_name and site_url as they're sent via headers.
        #
        # @return [Hash] serialized options
        def serialize
          super.except(:app_name, :site_url)
        end

        # Returns extra headers for OpenRouter API
        #
        # Maps app_name and site_url to OpenRouter's required headers:
        # - HTTP-Referer: site_url
        # - X-Title: app_name
        #
        # @return [Hash] headers hash
        def extra_headers
          deep_compact(
            "http-referer" => site_url.presence,
            "x-title"      => app_name.presence
          )
        end

        private

        def resolve_api_key(kwargs)
          kwargs["api_key"] ||
            ENV["OPENROUTER_API_KEY"] ||
            ENV["OPEN_ROUTER_API_KEY"] ||
            ENV["OPENROUTER_ACCESS_TOKEN"] ||
            ENV["OPEN_ROUTER_ACCESS_TOKEN"]
        end

        # Not Used as Part of Open Router
        def resolve_organization_id(kwargs) = nil
        def resolve_project_id(kwargs)      = nil

        def resolve_app_name(kwargs)
          if defined?(Rails) && Rails.application
            Rails.application.class.name.split("::").first
          end
        end

        def resolve_site_url(kwargs)
          # First check ActiveAgent kwargs
          return kwargs[:default_url_options][:host] if kwargs.dig(:default_url_options, :host)

          # Then check Rails routes default_url_options
          if defined?(Rails) && Rails.application&.routes&.default_url_options&.any?
            host     = Rails.application.routes.default_url_options[:host]
            port     = Rails.application.routes.default_url_options[:port]
            protocol = Rails.application.routes.default_url_options[:protocol] || "https"

            if host
              url = "#{protocol}://#{host}"
              url += ":#{port}" if port && port != 80 && port != 443
              return url
            end
          end

          # Finally check ActionMailer options as fallback
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
      end
    end
  end
end
