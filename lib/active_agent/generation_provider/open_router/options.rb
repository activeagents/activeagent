# frozen_string_literal: true

require_relative "../open_ai/options"
require_relative "response_format"
require_relative "prediction"
require_relative "provider_preferences"
require_relative "types"

module ActiveAgent
  module GenerationProvider
    module OpenRouter
      class Options < ActiveAgent::GenerationProvider::OpenAI::Options
        # Client Options
        attribute :uri_base, :string, default: "https://openrouter.ai/api/v1"
        attribute :app_name, :string, default: "ActiveAgent"
        attribute :site_url, :string

        # Prompting Options
        attribute :model,           :string,  default: "openrouter/auto"
        attribute :response_format, Types::ResponseFormatType.new
        attribute :max_tokens,      :integer
        attribute :stop # Can be string or array

        # LLM Parameters
        attribute :seed,               :integer
        attribute :top_p,              :float
        attribute :top_k,              :integer
        attribute :frequency_penalty,  :float
        attribute :presence_penalty,   :float
        attribute :repetition_penalty, :float
        attribute :top_logprobs,       :integer
        attribute :min_p,              :float
        attribute :top_a,              :float
        attribute :logit_bias # Hash of token_id => bias value

        # Tool calling (inherited from OpenAI but explicitly documented)
        # attribute :tools, :json
        # attribute :tool_choice, :json

        # Predicted outputs
        attribute :prediction, Types::PredictionType.new

        # OpenRouter-specific parameters
        attribute :transforms,                                   default: -> { [] } # Array of strings
        attribute :models,                                       default: -> { [] } # Array of model strings for fallback
        attribute :route,    :string,                            default: "fallback"
        attribute :provider, Types::ProviderPreferencesType.new, default: {}
        attribute :user,     :string # Stable identifier for end-users

        # Validations for parameters with specific ranges
        validates :max_tokens,         numericality: { greater_than_or_equal_to: 1 },                            allow_nil: true
        validates :top_p,              numericality: { greater_than: 0, less_than_or_equal_to: 1 },              allow_nil: true
        validates :top_k,              numericality: { greater_than_or_equal_to: 1 },                            allow_nil: true
        validates :frequency_penalty,  numericality: { greater_than_or_equal_to: -2, less_than_or_equal_to: 2 }, allow_nil: true
        validates :presence_penalty,   numericality: { greater_than_or_equal_to: -2, less_than_or_equal_to: 2 }, allow_nil: true
        validates :repetition_penalty, numericality: { greater_than: 0, less_than_or_equal_to: 2 },              allow_nil: true
        validates :min_p,              numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },  allow_nil: true
        validates :top_a,              numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },  allow_nil: true
        validates :route,              inclusion:    { in: [ "fallback" ] },                                     allow_nil: true

        # Backwards Compatibility
        delegate_attributes :data_collection, :enable_fallbacks, :sort, :ignore, :only, :quantizations, :max_price, to: :provider
        alias_attribute :fallback_models, :models

        def initialize(**settings)
          settings = settings.deep_symbolize_keys if settings.respond_to?(:deep_symbolize_keys)

          super(**deep_compact(settings.merge(
            app_name: settings[:app_name] || resolve_app_name(settings),
            site_url: settings[:site_url] || resolve_site_url(settings),
          )))
        end

        def chat_parameters
          deep_compact(
            super.merge(
              response_format: response_format&.to_h,
              stop:,
              max_tokens:,
              seed:,
              top_p:,
              top_k:,
              frequency_penalty:,
              presence_penalty:,
              repetition_penalty:,
              logit_bias:,
              top_logprobs:,
              min_p:,
              top_a:,
              prediction: prediction&.to_h,
              transforms:,
              models:,
              route:,
              provider: provider&.to_h,
              user:
            )
          )
        end

        protected

        def client_options_extra_headers
          {
            "http-referer" => site_url,
            "x-title"      => app_name
          }
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

          nil
        end
      end
    end
  end
end
