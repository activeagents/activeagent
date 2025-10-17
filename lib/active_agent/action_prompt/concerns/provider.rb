# frozen_string_literal: true

require_relative "../../providers/_base_provider"

module ActiveAgent
  module ActionPrompt
    # Configures and manages AI provider integration for action prompts.
    module Provider
      extend ActiveSupport::Concern

      included do
        class_attribute :_provider_klass, instance_accessor: false, instance_predicate: false

        delegate :provider_klass, to: :class
      end

      class_methods do
        # Sets the provider for this class.
        #
        # @param reference [Symbol, String, ActiveAgent::Provider::BaseProvider, Anthropic::Client, OpenAI::Client]
        #   Provider identifier, instance, or client
        # @raise [ArgumentError] if reference type is unsupported
        # @return [void]
        def provider=(reference)
          case reference
          when Symbol, String
            self._provider_klass = configuration(reference)

          when ActiveAgent::Providers::BaseProvider
            self._provider_klass = reference

          when ->(ref) { defined?(::Anthropic::Client) && ref.is_a?(::Anthropic::Client) }
            self._provider_klass = provider_load("Anthropic")

          when ->(ref) { defined?(::OpenAI) && ref.is_a?(::OpenAI::Client) }
            self._provider_klass = provider_load("OpenAI")
          else
            raise ArgumentError
          end
        end

        # Loads provider class from configuration.
        #
        # @param reference [Symbol, String] Provider identifier
        # @param options [Hash] Additional configuration options
        # @return [Class] Provider class
        # @raise [RuntimeError] if provider fails to load
        def provider_setup(reference, **options)
          type   = reference.to_sym
          config = { service: type.to_s.camelize }.merge(provider_config_load(type)).merge(options)
          provider_load(config[:service])

        rescue LoadError => e
          raise RuntimeError, "Failed to load provider #{type}: #{e.message}"
        end
        alias configuration provider_setup

        # Retrieves provider configuration.
        #
        # @param provider_type [Symbol, String] Provider identifier
        # @return [Hash] Configuration hash with symbolized keys
        def provider_config_load(provider_type)
          (ActiveAgent.config[provider_type.to_s] ||
            ActiveAgent.config.dig(ENV["RAILS_ENV"], provider_type.to_s) ||
            {}).deep_symbolize_keys
        end

        # Loads provider class by service name.
        #
        # @param service_name [String] Service name (e.g., "OpenAI", "Anthropic")
        # @return [Class] Provider class
        def provider_load(service_name)
          require "active_agent/providers/#{service_name.underscore}_provider"

          ActiveAgent::Providers.const_get("#{service_name.camelize}Provider")
        end

        # Returns the configured provider class.
        #
        # @return [Class, nil] Provider class if set
        def provider_klass = _provider_klass
      end
    end
  end
end
