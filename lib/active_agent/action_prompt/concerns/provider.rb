# frozen_string_literal: true

module ActiveAgent
  module ActionPrompt
    module Provider
      extend ActiveSupport::Concern

      included do
        class_attribute :_provider_klass, instance_accessor: false, instance_predicate: false

        delegate :provider_klass, to: :class
      end

      class_methods do
        def provider=(reference)
          case reference
          when Symbol, String
            self._provider_klass = configuration(reference)

          when ActiveAgent::Provider::BaseProvider
            self._provider_klass = reference

          when ::Anthropic::Client
            self._provider_klass = provider_load("Anthropic")

          when ::OpenAI::Client
            self._provider_klass = provider_load("OpenAI")
          else
            raise ArgumentError
          end
        end

        # @param reference [Symbol, String, ActiveAgent::Providers::BaseProvider]
        def configuration(reference, **options)
          type   = reference.to_sym
          config = provider_config(type).merge(options)

        raise "Failed to load provider #{type}: configuration not found for provider" if config[:service].nil?
          provider_load(config[:service])

        rescue LoadError => e
          raise RuntimeError, "Failed to load provider #{type}: #{e.message}"
        end

        # @param provider_type [Symbol, String, ActiveAgent::Providers::BaseProvider]
        def provider_config(provider_type)
          (ActiveAgent.config[provider_type.to_s] ||
            ActiveAgent.config.dig(ENV["RAILS_ENV"], provider_type.to_s) ||
            {}).deep_symbolize_keys
        end

        def provider_load(service_name)
          require "active_agent/providers/#{service_name.underscore}_provider"

          ActiveAgent::Providers.const_get("#{service_name.camelize}Provider")
        end

        def provider_name  = _provider_name
        def provider_klass = _provider_klass
      end
    end
  end
end
