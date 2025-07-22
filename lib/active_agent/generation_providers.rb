# frozen_string_literal: true

require "tmpdir"
require_relative "generation_provider/test_provider"

module ActiveAgent
  # = Active Agent \GenerationProviders
  #
  # This module handles everything related to prompt generation, from registering
  # new generation providers to configuring the prompt object to be sent.
  module GenerationProviders
    extend ActiveSupport::Concern

    included do
      # Do not make this inheritable, because we always want it to propagate
      cattr_accessor :raise_generation_errors, default: true
      cattr_accessor :perform_generations, default: true

      class_attribute :generation_providers, default: {}.freeze
      class_attribute :_generation_provider_name, default: :test
      class_attribute :_generation_provider_instance, default: nil

      add_generation_provider :test, ActiveAgent::GenerationProvider::TestProvider
    end

    module ClassMethods
      delegate :generations, :generations=, to: ActiveAgent::GenerationProvider::TestProvider

      def add_generation_provider(symbol, klass, default_options = {})
        class_attribute(:"#{symbol}_settings") unless respond_to?(:"#{symbol}_settings")
        public_send(:"#{symbol}_settings=", default_options)
        self.generation_providers = generation_providers.merge(symbol.to_sym => klass).freeze
      end

      def lazy_load_provider(provider_name)
        return if generation_providers.key?(provider_name)
        
        case provider_name
        when :openai
          require_relative "generation_provider/open_ai_provider"
          add_generation_provider :openai, ActiveAgent::GenerationProvider::OpenAIProvider
        when :anthropic
          require_relative "generation_provider/anthropic_provider"
          add_generation_provider :anthropic, ActiveAgent::GenerationProvider::AnthropicProvider
        when :ollama
          require_relative "generation_provider/ollama_provider"
          add_generation_provider :ollama, ActiveAgent::GenerationProvider::OllamaProvider
        when :open_router
          require_relative "generation_provider/open_router_provider"
          add_generation_provider :open_router, ActiveAgent::GenerationProvider::OpenRouterProvider
        else
          raise "Unknown generation provider: #{provider_name}"
        end
      end

      def generation_provider
        return _generation_provider_instance if _generation_provider_instance

        provider_name = _generation_provider_name
        lazy_load_provider(provider_name) unless generation_providers.key?(provider_name)
        
        provider_class = generation_providers[provider_name]
        provider_options = respond_to?(:"#{provider_name}_settings") ? public_send(:"#{provider_name}_settings") : {}
        
        self._generation_provider_instance = provider_class.new(provider_options || {})
      end

      def generation_provider=(provider)
        case provider
        when Symbol
          self._generation_provider_name = provider
          self._generation_provider_instance = nil  # Reset instance to force recreation
        when Class
          self._generation_provider_instance = provider.new
        else
          self._generation_provider_instance = provider
        end
      end

      def wrap_generation_behavior(prompt, provider = nil, options = nil) # :nodoc:
        provider ||= _generation_provider_name
        prompt.generation_handler = self

        case provider
        when NilClass
          raise "Generation provider cannot be nil"
        when Symbol
          lazy_load_provider(provider) unless generation_providers.key?(provider)
          if (klass = generation_providers[provider])
            prompt.generation_provider(klass, (send(:"#{provider}_settings") || {}).merge(options || {}))
          else
            raise "Invalid generation provider #{provider.inspect}"
          end
        else
          prompt.generation_provider(provider)
        end

        prompt.perform_generations = perform_generations
        prompt.raise_generation_errors = raise_generation_errors
      end
    end

    def generation_provider
      self.class.generation_provider
    end

    def wrap_generation_behavior!(*) # :nodoc:
      self.class.wrap_generation_behavior(prompt, *)
    end
  end
end
