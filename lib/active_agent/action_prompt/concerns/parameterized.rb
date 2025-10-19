# frozen_string_literal: true

module ActiveAgent
  module ActionPrompt
    # Provides parameterization support for agents, allowing you to pass variables
    # to agent actions that can be used in templates.
    #
    # When included in an agent class, this concern enables the ability to pass
    # parameters when calling agent actions, making agents reusable with different
    # data contexts.
    #
    # @example Basic usage
    #   class WelcomeAgent < ActiveAgent::Base
    #     def greet
    #       # Template can access params[:user_name]
    #     end
    #   end
    #
    #   # Pass parameters to the agent action
    #   WelcomeAgent.with(user_name: "Alice").greet.generate
    #
    # @example Using in templates
    #   # In greet.txt.erb template:
    #   # Hello <%= params[:user_name] %>!
    #
    # @example Multiple parameters
    #   OrderAgent.with(order_id: 123, customer: "John").process_order.generate
    #
    module Parameterized
      extend ActiveSupport::Concern

      included do
        attr_writer :params

        # Returns the parameters hash for this agent instance.
        #
        # @return [Hash] the parameters hash, defaults to empty hash if not set
        def params
          @params ||= {}
        end
      end

      module ClassMethods
        # Creates a parameterized agent proxy that will pass the given parameters
        # to the agent instance when an action is called.
        #
        # @param params [Hash] the parameters to pass to the agent instance
        # @return [ActiveAgent::ActionPrompt::Parameterized::Agent] a proxy object
        #   that will create parameterized generations when actions are called
        #
        # @example
        #   UserAgent.with(user_id: 123).send_notification.generate
        #
        def with(params = {})
          ActiveAgent::ActionPrompt::Parameterized::Agent.new(self, params)
        end
        alias_method :prompt_with, :with
      end

      # Proxy class that intercepts method calls to create parameterized generations.
      #
      # This class is returned by {ClassMethods#with} and acts as a proxy to the
      # actual agent class, capturing method calls to actions and creating
      # {Generation} instances with the stored parameters.
      #
      # @api private
      class Agent
        # @param agent [Class] the agent class to proxy
        # @param params [Hash] the parameters to pass to agent instances
        def initialize(agent, params)
          @agent = agent
          @params = params
        end

        # Intercepts calls to agent action methods and creates parameterized generations.
        #
        # @param method_name [Symbol] the name of the action method being called
        # @param args [Array] arguments to pass to the action method
        # @return [ActiveAgent::ActionPrompt::Parameterized::Generation] a generation
        #   instance with the stored parameters
        # @raise [NoMethodError] if the method doesn't exist on the agent class
        def method_missing(method_name, ...)
          if @agent.public_instance_methods.include?(method_name)
            ActiveAgent::ActionPrompt::Parameterized::Generation.new(@agent, method_name, @params, ...)
          else
            super
          end
        end

        # @param method [Symbol] the method name to check
        # @param include_all [Boolean] whether to include private and protected methods
        # @return [Boolean] true if the agent responds to the method
        def respond_to_missing?(method, include_all = false)
          @agent.respond_to?(method, include_all)
        end
      end

      # A specialized generation class that handles parameterized agent actions.
      #
      # This class extends {ActiveAgent::Generation} to support passing parameters
      # to agent instances before processing actions. It ensures parameters are
      # properly set both for immediate processing and when enqueuing background jobs.
      #
      # @api private
      class Generation < ActiveAgent::Generation
        # @param agent_class [Class] the agent class
        # @param action [Symbol, String] the action method name
        # @param params [Hash] the parameters to set on the agent instance
        # @param args [Array] additional arguments for the action method
        def initialize(agent_class, action, params, ...)
          super(agent_class, action, ...)
          @params = params
        end

        private

        # Creates and processes an agent instance with parameters set.
        #
        # @return [ActiveAgent::Base] the processed agent instance with params
        def processed_agent
          @processed_agent ||= @agent_class.new.tap do |agent|
            agent.params = @params
            agent.process @action, *@args
          end
        end

        # Enqueues a generation job with parameters included.
        #
        # This method ensures that when a parameterized generation is enqueued,
        # the parameters are passed to the background job so they can be
        # properly set when the job executes.
        #
        # @param generation_method [Symbol, String] the generation method to call
        # @param job_options [Hash] options to pass to the job (e.g., queue, priority)
        # @return [Object] the enqueued job instance
        def enqueue_generation(generation_method, job_options = {})
          if processed?
            super
          else
            @agent_class.generation_job.set(job_options).perform_later(
              @agent_class.name, @action.to_s, generation_method.to_s, params: @params, args: @args
            )
          end
        end
      end
    end
  end
end
