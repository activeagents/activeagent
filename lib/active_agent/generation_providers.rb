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
      class_attribute :generation_provider, default: :test

      add_generation_provider :test, ActiveAgent::GenerationProvider::TestProvider
    end

    module ClassMethods
      delegate :generations, :generations=, to: ActiveAgent::GenerationProvider::TestProvider

      def add_generation_provider(symbol, klass, default_options = {})
        class_attribute(:"#{symbol}_settings") unless respond_to?(:"#{symbol}_settings")
        public_send(:"#{symbol}_settings=", default_options)
        self.generation_providers = generation_providers.merge(symbol.to_sym => klass).freeze
      end

      def wrap_generation_behavior(prompt, provider = nil, options = nil) # :nodoc:
        provider ||= generation_provider
        prompt.generation_handler = self

        case provider
        when NilClass
          raise "Generation provider cannot be nil"
        when Symbol
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

    def wrap_generation_behavior!(*) # :nodoc:
      self.class.wrap_generation_behavior(prompt, *)
    end
  end
end
