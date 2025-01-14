# frozen_string_literal: true

require "tmpdir"
require_relative "action_prompt"

module ActiveAgent
  # = Active Agent \GenerationM74ethods
  #
  # This module handles everything related to prompt generation, from registering
  # new generation methods to configuring the prompt object to be sent.
  module GenerationMethods
    extend ActiveSupport::Concern

    included do
      # Do not make this inheritable, because we always want it to propagate
      cattr_accessor :raise_generation_errors, default: true
      cattr_accessor :perform_generations, default: true

      class_attribute :generation_methods, default: {}.freeze
      class_attribute :generation_method, default: :smtp

      add_generation_method :test, ActiveAgent::ActionPrompt::TestAgent
    end

    module ClassMethods
      delegate :generations, :generations=, to: ActiveAgent::ActionPrompt::TestAgent

      def add_generation_method(symbol, klass, default_options = {})
        class_attribute(:"#{symbol}_settings") unless respond_to?(:"#{symbol}_settings")
        public_send(:"#{symbol}_settings=", default_options)
        self.generation_methods = generation_methods.merge(symbol.to_sym => klass).freeze
      end

      def wrap_generation_behavior(prompt, method = nil, options = nil) # :nodoc:
        method ||= generation_method
        prompt.generation_handler = self

        case method
        when NilClass
          raise "Generation method cannot be nil"
        when Symbol
          if (klass = generation_methods[method])
            prompt.generation_method(klass, (send(:"#{method}_settings") || {}).merge(options || {}))
          else
            raise "Invalid generation method #{method.inspect}"
          end
        else
          prompt.generation_method(method)
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
