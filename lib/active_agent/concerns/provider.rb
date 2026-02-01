# frozen_string_literal: true

require_relative "../providers/_base_provider"

module ActiveAgent
  # Configures and manages AI provider integration for action prompts.
  module Provider
    extend ActiveSupport::Concern

    # "Your tacky and I hate you" - Billy, https://youtu.be/dsheboxJNgQ?si=tzDlJ7sdSxM4RjSD
    PROVIDER_SERVICE_NAMES_REMAPS = {
      "Openrouter"  => "OpenRouter",
      "Openai"      => "OpenAI",
      "AzureOpenai" => "AzureOpenAI",
      "Azureopenai" => "AzureOpenAI"
    }

    included do
      class_attribute :_prompt_provider_klass, instance_accessor: false, instance_predicate: false
      class_attribute :_embed_provider_klass,  instance_accessor: false, instance_predicate: false

      delegate :prompt_provider_klass, :embed_provider_klass, to: :class
    end

    class_methods do
      # Sets the prompt provider for this class.
      #
      # @param reference [Symbol, String, ActiveAgent::Provider::BaseProvider, Anthropic::Client, OpenAI::Client]
      #   Provider identifier, instance, or client
      # @raise [ArgumentError] if reference type is unsupported
      # @return [void]
      def prompt_provider=(reference)
        case reference
        when Symbol, String
          self._prompt_provider_klass = configuration(reference)

        when ActiveAgent::Providers::BaseProvider
          self._prompt_provider_klass = reference

        when ->(ref) { defined?(::Anthropic) && ref.is_a?(::Anthropic::Client) }
          self._prompt_provider_klass = provider_load("Anthropic")

        when ->(ref) { defined?(::OpenAI) && ref.is_a?(::OpenAI::Client) }
          self._prompt_provider_klass = provider_load("OpenAI")
        else
          raise ArgumentError
        end
      end

      # Sets the embed provider for this class.
      #
      # @param reference [Symbol, String, ActiveAgent::Provider::BaseProvider, Anthropic::Client, OpenAI::Client]
      #   Provider identifier, instance, or client
      # @raise [ArgumentError] if reference type is unsupported
      # @return [void]
      def embed_provider=(reference)
        case reference
        when Symbol, String
          self._embed_provider_klass = configuration(reference)

        when ActiveAgent::Providers::BaseProvider
          self._embed_provider_klass = reference

        when ->(ref) { defined?(::OpenAI) && ref.is_a?(::OpenAI::Client) }
          self._embed_provider_klass = provider_load("OpenAI")
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
        path = [ ENV["RAILS_ENV"], provider_type.to_s ].compact

        path.length.downto(1).map do |index|
          ActiveAgent.configuration.dig(*path[(path.length - index)..])
        end.compact.first&.deep_symbolize_keys || {}
      end

      # Loads provider class by service name.
      #
      # @param service_name [String] Service name (e.g., "OpenAI", "Anthropic")
      # @return [Class] Provider class
      def provider_load(service_name)
        require "active_agent/providers/#{service_name.underscore}_provider"

        service_name = Hash.new(service_name).merge!(PROVIDER_SERVICE_NAMES_REMAPS)[service_name]

        ActiveAgent::Providers.const_get("#{service_name.camelize}Provider")
      end

      # Returns the configured prompt provider class.
      #
      # @return [Class, nil] Prompt provider class if set
      def prompt_provider_klass = _prompt_provider_klass

      # Returns the configured embed provider class.
      #
      # @return [Class, nil] Embed provider class if set
      def embed_provider_klass = _embed_provider_klass
    end
  end
end
