# frozen_string_literal: true

module ActiveAgent
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

    class_methods do
      # Creates a parameterized agent proxy that will pass the given parameters
      # to the agent instance when an action is called.
      #
      # @param params [Hash] the parameters to pass to the agent instance
      # @return [ActiveAgent::Parameterized::Agent] a proxy object
      #   that will create parameterized generations when actions are called
      #
      # @example
      #   UserAgent.with(user_id: 123).send_notification.generate
      #
      def with(params = {})
        ActiveAgent::Parameterized::Agent.new(self, params)
      end
      alias_method :prompt_with, :with

      # Creates a direct prompt generation without defining an action method.
      #
      # This allows you to generate prompts inline without needing to define
      # an action method on the agent class.
      #
      # @param messages [Array] message strings or hashes to add to conversation
      # @param options [Hash] parameters to merge into prompt context
      # @return [ActiveAgent::Parameterized::Generation] a generation instance
      #   ready for generate_now, generate_later, etc.
      #
      # @example Direct prompt generation
      #   MyAgent.prompt(message: "Hello world").generate_now
      #
      # @example With multiple messages
      #   MyAgent.prompt(messages: ["First", "Second"]).generate_now
      #
      # @example With options
      #   MyAgent.prompt(message: "Hello", temperature: 0.8).generate_now
      def prompt(*messages, **options)
        ActiveAgent::Parameterized::DirectGeneration.new(self, :prompt, {}, *messages, **options)
      end

      # Creates a direct embed generation without defining an action method.
      #
      # This allows you to generate embeddings inline without needing to define
      # an action method on the agent class.
      #
      # @param input [String, Array<String>, nil] text to embed
      # @param options [Hash] parameters to merge into embedding context
      # @return [ActiveAgent::Parameterized::Generation] a generation instance
      #   ready for embed_now, embed_later, etc.
      #
      # @example Direct embedding
      #   MyAgent.embed(input: "Text to embed").embed_now
      #
      # @example With array input
      #   MyAgent.embed(input: ["First", "Second"]).embed_now
      #
      # @example With options
      #   MyAgent.embed(input: "Text", model: "text-embedding-3-large").embed_now
      def embed(input = nil, **options)
        ActiveAgent::Parameterized::DirectGeneration.new(self, :embed, {}, input, **options)
      end
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
      # @return [ActiveAgent::Parameterized::Generation] a generation
      #   instance with the stored parameters
      # @raise [NoMethodError] if the method doesn't exist on the agent class
      def method_missing(method_name, ...)
        if @agent.public_instance_methods.include?(method_name)
          ActiveAgent::Parameterized::Generation.new(@agent, method_name, @params, ...)
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
      def agent
        @agent ||= agent_class.new.tap do |agent|
          agent.params = @params
          agent.process(action_name, *args, **kwargs)
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
          agent_class.generation_job.set(job_options).perform_later(
            agent_class.name, action_name.to_s, generation_method.to_s, params: @params, args: args, kwargs: kwargs
          )
        end
      end
    end

    # A specialized generation class for direct prompt/embed calls without actions.
    #
    # This class handles cases where you want to call Agent.prompt(...).generate_now
    # or Agent.embed(...).generate_now without defining an action method.
    #
    # @api private
    class DirectGeneration < Generation
      # @param agent_class [Class] the agent class
      # @param generation_type [Symbol] either :prompt or :embed
      # @param params [Hash] the parameters to set on the agent instance
      # @param args [Array] messages for prompt or input for embed
      # @param options [Hash] additional options (temperature, model, etc.)
      def initialize(agent_class, generation_type, params, *args, **options)
        @generation_type = generation_type
        @direct_args = args
        @direct_options = options

        # Use a synthetic action name that won't conflict with real methods
        super(agent_class, :"__direct_#{generation_type}__", params)
      end

      # Override generate_now to route to correct method based on generation type
      def generate_now
        case @generation_type
        when :prompt
          prompt_now
        when :embed
          embed_now
        end
      end

      # Override generate_now! to route to correct method based on generation type
      def generate_now!
        case @generation_type
        when :prompt
          prompt_now!
        when :embed
          # For embed, we don't have a separate embed_now! method, so use embed_now
          embed_now
        end
      end

      # Generates a preview based on generation type.
      #
      # @return [String] markdown-formatted preview for prompt generations
      # @raise [NotImplementedError] for embed generations (not yet supported)
      def preview
        case @generation_type
        when :prompt
          prompt_preview
        when :embed
          raise NotImplementedError, "Embed previewing is not supported"
        end
      end

      private

      # Creates and processes an agent instance for direct generation.
      #
      # Instead of calling a real action method, this directly calls the
      # prompt() or embed() method on the agent instance with the provided arguments.
      #
      # @return [ActiveAgent::Base] the processed agent instance
      def agent
        @agent ||= agent_class.new.tap do |agent|
          agent.params = @params

          # Directly call prompt or embed method instead of processing an action
          case @generation_type
          when :prompt
            agent.send(:prompt, *@direct_args, **@direct_options)
          when :embed
            agent.send(:embed, *@direct_args, **@direct_options)
          end
        end
      end

      # Enqueues a direct generation job.
      #
      # @param generation_method [Symbol, String] the generation method to call
      # @param job_options [Hash] options to pass to the job
      # @return [Object] the enqueued job instance
      def enqueue_generation(generation_method, job_options = {})
        if processed?
          super
        else
          # For direct generations, we need to store the generation type and options
          agent_class.generation_job.set(job_options).perform_later(
            agent_class.name,
            action_name.to_s,
            generation_method.to_s,
            params: @params,
            args: args,
            kwargs: kwargs,
            direct_generation_type: @generation_type,
            direct_args: @direct_args,
            direct_options: @direct_options
          )
        end
      end
    end
  end
end
