# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    extend ActiveSupport::Concern

    included do
      class_attribute :_generation_provider_name, instance_accessor: false, instance_predicate: false
      class_attribute :_generation_provider, instance_accessor: false, instance_predicate: false

      delegate :generation_provider, to: :class
    end

    module ClassMethods
      def configuration(name_or_provider, **options)
        config = ActiveAgent.config[name_or_provider.to_s] || ActiveAgent.config.dig(ENV["RAILS_ENV"], name_or_provider.to_s) || {}

        config = { "service" => "OpenAI" } if config.empty? && name_or_provider == :openai
        config.merge!(options)
      raise "Failed to load provider #{name_or_provider}: configuration not found for provider"  if config["service"].nil?
        configure_provider(config)
      rescue LoadError => e
        raise RuntimeError, "Failed to load provider #{name_or_provider}: #{e.message}"
      end

      def configure_provider(config)
        service_name = config["service"]
        require "active_agent/generation_provider/#{service_name.underscore}_provider"
        ActiveAgent::GenerationProvider.const_get("#{service_name.camelize}Provider").new(config)
      end

      def generation_provider
        self.generation_provider = :openai if _generation_provider.nil?
        _generation_provider
      end

      def generation_provider_name
        self.generation_provider = :openai if _generation_provider_name.nil?
        _generation_provider_name
      end

      def generation_provider=(name_or_provider)
        case name_or_provider
        when Symbol, String
          provider = configuration(name_or_provider)
          assign_provider(name_or_provider.to_s, provider)
        when OpenAI::Client
          name = :openai
          assign_provider(name, name_or_provider)
        else
          raise ArgumentError
        end
      end

      private

      def assign_provider(provider_name, generation_provider)
        self._generation_provider_name = provider_name
        self._generation_provider = generation_provider
      end
    end

    def generation_provider
      self.class.generation_provider
    end
  end
end
