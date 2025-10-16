# frozen_string_literal: true

require_relative "../open_ai/options"
require_relative "requests/response_format"
require_relative "requests/prediction"
require_relative "requests/provider_preferences"
require_relative "requests/types"

module ActiveAgent
  module Providers
    module OpenRouter
      class Options < ActiveAgent::Providers::OpenAI::Options
        attribute :uri_base, :string, as: "https://openrouter.ai/api/v1"
        attribute :app_name, :string
        attribute :site_url, :string

        def initialize(kwargs = {})
          kwargs = kwargs.deep_symbolize_keys if kwargs.respond_to?(:deep_symbolize_keys)

          super(**deep_compact(kwargs.merge(
            app_name: kwargs[:app_name] || resolve_app_name(kwargs),
            site_url: kwargs[:site_url] || resolve_site_url(kwargs),
          )))
        end

        def to_hc
          super.tap do |hash|
            if site_url || app_name
              hash[:extra_headers] = {
                "http-referer" => site_url,
                "x-title"      => app_name
              }.compact
            end
          end
        end

        private

        # Not Used as Part of Open Router
        def resolve_organization_id(settings) = nil
        def resolve_admin_token(settings)     = nil

        def resolve_access_token(settings)
          settings["api_key"] ||
            ENV["OPENROUTER_API_KEY"] ||
            ENV["OPEN_ROUTER_API_KEY"] ||
            ENV["OPENROUTER_ACCESS_TOKEN"] ||
            ENV["OPEN_ROUTER_ACCESS_TOKEN"]
        end

        def resolve_app_name(settings)
          if defined?(Rails) && Rails.application
            Rails.application.class.name.split("::").first
          else
            "ActiveAgent"
          end
        end

        def resolve_site_url(settings)
          # First check ActiveAgent settings
          return settings[:default_url_options][:host] if settings.dig(:default_url_options, :host)

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

          "https://activeagents.ai/"
        end
      end
    end
  end
end
