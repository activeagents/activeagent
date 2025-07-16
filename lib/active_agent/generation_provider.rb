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
      def configuration(provider_name, **options)
        config = ActiveAgent.config[provider_name.to_s] || ActiveAgent.config.dig(ENV["RAILS_ENV"], provider_name.to_s)

        raise "Configuration not found for provider: #{provider_name}" unless config
        config.merge!(options)
        configure_provider(config)
      end

      def configure_provider(config)
        require "active_agent/generation_provider/#{config["service"].underscore}_provider"
        ActiveAgent::GenerationProvider.const_get("#{config["service"].camelize}Provider").new(config)
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
