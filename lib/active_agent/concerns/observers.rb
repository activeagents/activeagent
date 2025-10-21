# frozen_string_literal: true

module ActiveAgent
  # Provides observer and interceptor functionality for monitoring and modifying
  # the prompt generation lifecycle.
  #
  # Observers are notified when prompts are generated and can react to events
  # without modifying the prompt itself. Common use cases include logging,
  # analytics, auditing, and notifications.
  #
  # Interceptors are called before prompts are sent to AI providers and can
  # modify or prevent the prompt from being sent. Common use cases include
  # content filtering, prompt modification, access control, and rate limiting.
  module Observers
    extend ActiveSupport::Concern

    module ClassMethods
      # Register one or more Observers which will be notified when prompt is generated.
      #
      # @param observers [Array<Class, String, Symbol>] Observer classes or names to register
      # @return [void]
      #
      # @example Register multiple observers
      #   MyAgent.register_observers(PromptLogger, :analytics_tracker)
      def register_observers(*observers)
        observers.flatten.compact.each { |observer| register_observer(observer) }
      end

      # Unregister one or more previously registered Observers.
      #
      # @param observers [Array<Class, String, Symbol>] Observer classes or names to unregister
      # @return [void]
      #
      # @example Unregister multiple observers
      #   MyAgent.unregister_observers(PromptLogger, :analytics_tracker)
      def unregister_observers(*observers)
        observers.flatten.compact.each { |observer| unregister_observer(observer) }
      end

      # Register one or more Interceptors which will be called before prompt is sent.
      #
      # @param interceptors [Array<Class, String, Symbol>] Interceptor classes or names to register
      # @return [void]
      #
      # @example Register multiple interceptors
      #   MyAgent.register_interceptors(ContentFilter, :rate_limiter)
      def register_interceptors(*interceptors)
        interceptors.flatten.compact.each { |interceptor| register_interceptor(interceptor) }
      end

      # Unregister one or more previously registered Interceptors.
      #
      # @param interceptors [Array<Class, String, Symbol>] Interceptor classes or names to unregister
      # @return [void]
      #
      # @example Unregister multiple interceptors
      #   MyAgent.unregister_interceptors(ContentFilter, :rate_limiter)
      def unregister_interceptors(*interceptors)
        interceptors.flatten.compact.each { |interceptor| unregister_interceptor(interceptor) }
      end

      # Register an Observer which will be notified when prompt is generated.
      #
      # Either a class, string, or symbol can be passed in as the Observer.
      # If a string or symbol is passed in it will be camelized and constantized.
      #
      # @param observer [Class, String, Symbol] The observer to register
      # @return [void]
      #
      # @example Register with class
      #   MyAgent.register_observer(PromptLogger)
      #
      # @example Register with string
      #   MyAgent.register_observer("PromptLogger")
      #
      # @example Register with symbol
      #   MyAgent.register_observer(:prompt_logger)
      def register_observer(observer)
        Prompt.register_observer(observer_class_for(observer))
      end

      # Unregister a previously registered Observer.
      #
      # Either a class, string, or symbol can be passed in as the Observer.
      # If a string or symbol is passed in it will be camelized and constantized.
      #
      # @param observer [Class, String, Symbol] The observer to unregister
      # @return [void]
      #
      # @example Unregister with class
      #   MyAgent.unregister_observer(PromptLogger)
      def unregister_observer(observer)
        Prompt.unregister_observer(observer_class_for(observer))
      end

      # Register an Interceptor which will be called before prompt is sent.
      #
      # Either a class, string, or symbol can be passed in as the Interceptor.
      # If a string or symbol is passed in it will be camelized and constantized.
      #
      # @param interceptor [Class, String, Symbol] The interceptor to register
      # @return [void]
      #
      # @example Register with class
      #   MyAgent.register_interceptor(ContentFilter)
      #
      # @example Register with string
      #   MyAgent.register_interceptor("ContentFilter")
      #
      # @example Register with symbol
      #   MyAgent.register_interceptor(:content_filter)
      def register_interceptor(interceptor)
        Prompt.register_interceptor(observer_class_for(interceptor))
      end

      # Unregister a previously registered Interceptor.
      #
      # Either a class, string, or symbol can be passed in as the Interceptor.
      # If a string or symbol is passed in it will be camelized and constantized.
      #
      # @param interceptor [Class, String, Symbol] The interceptor to unregister
      # @return [void]
      #
      # @example Unregister with class
      #   MyAgent.unregister_interceptor(ContentFilter)
      def unregister_interceptor(interceptor)
        Prompt.unregister_interceptor(observer_class_for(interceptor))
      end

      private

      # Converts observer/interceptor value to class.
      #
      # @param value [Class, String, Symbol] The observer/interceptor identifier
      # @return [Class] The observer/interceptor class
      # @api private
      def observer_class_for(value) # :nodoc:
        case value
        when String, Symbol
          value.to_s.camelize.constantize
        else
          value
        end
      end
    end
  end
end
