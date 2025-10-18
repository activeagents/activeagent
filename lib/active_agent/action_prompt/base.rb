require "active_support/core_ext/hash/except"
require "active_support/core_ext/module/anonymous"
require "active_support/core_ext/string/inflections"

Dir[File.join(__dir__, "concerns", "*.rb")].each { |file| require file }

module ActiveAgent
  module ActionPrompt
    # Foundation for creating AI-powered agents that generate responses, handle tool calls,
    # and manage conversations.
    #
    # Extends AbstractController::Base with AI-specific functionality including provider
    # management, streaming, and tooling capabilities.
    #
    # @example Basic agent setup
    #   class MyAgent < ActiveAgent::ActionPrompt::Base
    #     generate_with :openai, model: "gpt-4"
    #
    #     def greet
    #       prompt instructions: "Greet the user warmly"
    #     end
    #   end
    #
    # @see AbstractController::Base
    class Base < AbstractController::Base
      abstract!

      include AbstractController::Rendering
      include AbstractController::Logger
      include AbstractController::Helpers
      include AbstractController::Translation
      include AbstractController::AssetPaths
      include AbstractController::Callbacks
      include AbstractController::Caching

      include ActionView::Layouts

      include Provider
      include Streaming
      include Tooling
      include Rescue
      include View

      include Callbacks
      include Observers
      include Parameterized
      include Previews
      include QueuedGeneration

      PROTECTED_IVARS = AbstractController::Rendering::DEFAULT_PROTECTED_INSTANCE_VARIABLES + [ :@_action_has_layout ]

      class_attribute :prompt_options
      class_attribute :embed_options
      class_attribute :default_params, default: {
        mime_version: "1.0",
        charset: "UTF-8",
        content_type: "text/plain",
        parts_order: [ "text/plain", "text/enriched", "text/html" ]
      }.freeze

      # Sets default parameters applied to all actions unless overridden.
      #
      # @param value [Hash, nil] parameters to merge, or nil to return current defaults
      # @return [Hash]
      #
      # @example Setting defaults
      #   default temperature: 0.7, max_tokens: 1000
      #
      # @example Through app configuration
      #   config.action_agent.default(temperature: 0.5)
      def self.default(value = nil)
        self.default_params = default_params.merge(value).freeze if value
        default_params
      end

      # Allows setting defaults through app configuration.
      #
      # @param value [Hash]
      # @return [Hash]
      #
      # @example
      #   config.action_agent.default_options = { temperature: 0.5 }
      class << self
        alias_method :default_options=, :default
      end

      # Configures the generation provider and options for prompt generation.
      #
      # Primary method for defining how an agent class generates prompts. Specifies
      # the AI provider and shared configuration options across all actions.
      #
      # @param provider_reference [Symbol, String] generation provider (e.g., :openai, :anthropic)
      # @param agent_options [Hash] configuration options shared across actions
      # @return [void]
      #
      # @example Basic setup
      #   generate_with :openai
      #
      # @example With custom instructions
      #   generate_with :openai, instructions: "You are a helpful assistant"
      #
      # @example With model options
      #   generate_with :anthropic, temperature: 0.7, model: "claude-3"
      def self.generate_with(provider_reference, **agent_options)
        self.prompt_provider = provider_reference

        global_options    = provider_config_load(provider_reference)
        inherited_options = (self.prompt_options || {}).except(:instructions) # Don't inherit instructions from parent

        # Different Service, different APIs
        if global_options[:service] != inherited_options[:service]
          inherited_options.extract!(:service, :api_version)
        end

        self.prompt_options = global_options.merge(inherited_options).merge(agent_options)
      end

      # Configures the embedding provider and options for embedding generation.
      #
      # @param provider_reference [Symbol, String] embedding provider (e.g., :openai, :anthropic)
      # @param agent_options [Hash] configuration options for embedding generation
      # @return [void]
      #
      # @example Basic setup
      #   embed_with :openai
      #
      # @example With custom model
      #   embed_with :openai, model: "text-embedding-3-large"
      def self.embed_with(provider_reference, **agent_options)
        self.embed_provider = provider_reference

        global_options    = provider_config_load(provider_reference)
        inherited_options = self.embed_options || {}

        self.embed_options = global_options.merge(inherited_options).merge(agent_options)
      end

      # Handles method calls for action methods that don't exist as class methods.
      #
      # @param method_name [Symbol]
      # @param args [Array]
      # @return [Generation]
      # @api private
      def self.method_missing(method_name, ...)
        if action_methods.include?(method_name.name)
          Generation.new(self, method_name, ...)
        else
          super
        end
      end
      private_class_method :method_missing

      # @param method [Symbol]
      # @param include_all [Boolean]
      # @return [Boolean]
      # @api private
      def self.respond_to_missing?(method, include_all = false)
        action_methods.include?(method.name) || super
      end
      private_class_method :respond_to_missing?

      delegate :agent_name, to: :class

      # @!attribute [w] agent_name
      #   @return [String]
      attr_writer :agent_name
      alias_method :controller_path, :agent_name

      # @!attribute [rw] prompt_options
      #   Action-level prompt options merged with agent prompt options.
      #   @return [Hash]
      attr_internal :prompt_options

      # @!attribute [rw] embed_options
      #   Action-level embed options merged with agent embed options.
      #   @return [Hash]
      attr_internal :embed_options

      # Initializes a new agent instance with deep-duplicated class-level options.
      #
      # @api private
      def initialize # :nodoc:
        super
        self.prompt_options = self.class.prompt_options&.deep_dup || {}
        self.embed_options  = self.class.embed_options&.deep_dup  || {}
      end

      # Returns the agent name, used as a path for view lookup.
      #
      # @return [String] agent name or "anonymous" for anonymous agents
      def agent_name
        @agent_name ||= self.class.anonymous? ? "anonymous" : self.class.name.underscore
      end

      # Processes an agent action with ActiveSupport::Notifications instrumentation.
      #
      # Actions can be triggered externally through the public API (e.g., Agent.action_name.generate_now)
      # or internally through tool calls during AI generation workflows.
      #
      # @param method_name [Symbol, String] action method to process
      # @param args [Array]
      # @param kwargs [Hash]
      # @return [void]
      def process(method_name, *args, **kwargs) # :nodoc:
        payload = { agent: self.class.name, action: method_name, args:, kwargs: }

        ActiveSupport::Notifications.instrument("process.action_prompt.active_agent", payload) do
          super
        end
      end

      # Merges action-level parameters into the prompt context.
      #
      # Call from within an action to apply action-specific parameters.
      # Processing is deferred until execution to maximize available context.
      #
      # @param new_options [Hash] parameters to merge into prompt context
      # @return [void]
      #
      # @example
      #   def my_action
      #     prompt temperature: 0.8, instructions: "Be creative"
      #   end
      def prompt(new_options = {})
        prompt_options.merge!(new_options)
      end

      # Merges action-level parameters into the embedding context.
      #
      # @param new_options [Hash] parameters to merge into embedding context
      # @return [void]
      #
      # @example
      #   def my_embed_action
      #     embed model: "text-embedding-3-large"
      #   end
      def embed(new_options = {})
        embed_options.merge!(new_options)
      end

      # Executes prompt generation using the configured provider and options.
      #
      # Core execution point triggered by +generate_now+ or +generate_later+ workflows.
      #
      # @return [ActiveAgent::Providers::Response]
      # @raise [RuntimeError] if no prompt provider is configured
      def process_prompt
        fail "Prompt Provider not Configured" unless prompt_provider_klass

        parameters = prompt_options.merge(
          exception_handler:,
          stream_broadcaster:,
          tools_function:,
          instructions: prompt_view_instructions(prompt_options[:instructions])
        ).compact

        prompt_provider_klass.new(**parameters).prompt
      end

      # Executes embedding generation using the configured provider and options.
      #
      # @return [ActiveAgent::Providers::Response]
      # @raise [RuntimeError] if no embed provider is configured
      def process_embed
        fail "Embed Provider not Configured" unless embed_provider_klass

        parameters = embed_options.merge(
          exception_handler:
        ).compact

        embed_provider_klass.new(**parameters).embed
      end

      private

      # Returns available action methods, excluding ActiveAgent::Base methods and current action.
      #
      # @return [Array<String>]
      def action_methods
        super - ActiveAgent::Base.public_instance_methods(false).map(&:to_s) - [ action_name ]
      end

      # Provides instrumentation payload for caching and monitoring.
      #
      # @param key [String] cache key or operation identifier
      # @return [Hash]
      def instrument_payload(key)
        {
          agent: agent_name,
          key: key
        }
      end

      # @return [String]
      def instrument_name
        "active_agent"
      end

      # Returns protected instance variables not exposed in template contexts.
      #
      # @return [Array<String>]
      def _protected_ivars
        PROTECTED_IVARS
      end

      ActiveSupport.run_load_hooks(:active_agent, self)
    end
  end
end
