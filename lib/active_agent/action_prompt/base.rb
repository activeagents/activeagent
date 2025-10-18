require "active_support/core_ext/hash/except"
require "active_support/core_ext/module/anonymous"
require "active_support/core_ext/string/inflections"

require "active_agent/action_prompt/action"

Dir[File.join(__dir__, "concerns", "*.rb")].each { |file| require file }
require_relative "null_prompt"

module ActiveAgent
  module ActionPrompt
    # Base class for all ActiveAgent action prompt controllers.
    #
    # This class provides the foundation for creating AI-powered agents that can generate
    # responses, handle tool calls, and manage conversations. It extends AbstractController::Base
    # with AI-specific functionality including provider management, streaming, and tooling.
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

      helper ActiveAgent::PromptHelper

      class_attribute :prompt_options
      class_attribute :embed_options
      class_attribute :default_params, default: {
        mime_version: "1.0",
        charset: "UTF-8",
        content_type: "text/plain",
        parts_order: [ "text/plain", "text/enriched", "text/html" ]
      }.freeze

      # Define how the agent should generate content
      # Sets up the generation provider and options for the agent.
      #
      # This is the main method called when defining an agent class to configure
      # how prompts will be generated. It allows specifying the AI provider and
      # any generation options.
      #
      # @param provider [Symbol, String] The generation provider to use (e.g., :openai, :anthropic)
      # @param options [Hash] Configuration options that are shared across the actions
      #
      # @return [void]
      #
      # @example Basic setup with provider
      #   generate_with :openai
      #
      # @example With custom instructions
      #   generate_with :openai, instructions: "You are a helpful assistant"
      #
      # @example With additional options
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

      # Configure how the agent should generate embeddings.
      #
      # Sets up the embedding provider and options for the agent.
      # Similar to generate_with but specifically for embedding operations.
      #
      # @param provider_reference [Symbol, String] The embedding provider to use (e.g., :openai, :anthropic)
      # @param agent_options [Hash] Configuration options for embedding generation
      # @return [void]
      #
      # @example Basic embedding setup
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

      # Sets default parameters for the agent class.
      #
      # These defaults are applied to all actions unless overridden.
      # Can be configured through app configuration.
      #
      # @param value [Hash, nil] Default parameters to merge, or nil to return current defaults
      # @return [Hash] The current default parameters
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
      # @param value [Hash] Default parameters to set
      # @return [Hash] The updated default parameters
      #
      # @example
      #   config.action_agent.default_options = { temperature: 0.5 }
      class << self
        alias_method :default_options=, :default
      end

      # Handles method calls for action methods that don't exist as class methods.
      #
      # Creates a Generation instance for valid action methods.
      #
      # @param method_name [Symbol] The method name being called
      # @param args [Array] Arguments passed to the method
      # @return [Generation] A new Generation instance for the action
      # @api private
      def self.method_missing(method_name, ...)
        if action_methods.include?(method_name.name)
          Generation.new(self, method_name, ...)
        else
          super
        end
      end
      private_class_method :method_missing

      # Checks if the class responds to a given method name.
      #
      # @param method [Symbol] The method name to check
      # @param include_all [Boolean] Whether to include private methods
      # @return [Boolean] true if the method is an action method or handled by super
      # @api private
      def self.respond_to_missing?(method, include_all = false)
        action_methods.include?(method.name) || super
      end
      private_class_method :respond_to_missing?

      delegate :agent_name, to: :class

      # @!attribute [w] agent_name
      #   Allows setting the name of current agent.
      #   @return [String] The agent name
      attr_writer :agent_name
      alias_method :controller_path, :agent_name

      # @!attribute [rw] prompt_options
      #   Action-level prompt options merged with agent prompt options.
      #   @return [Hash] The current prompt options
      attr_internal :prompt_options

      # @!attribute [rw] embed_options
      #   Action-level embed options merged with agent embed options.
      #   @return [Hash] The current embed options
      attr_internal :embed_options

      # Initializes a new agent instance.
      #
      # Sets up prompt and embed options by deep duplicating class-level options
      # to ensure instance-level modifications don't affect the class.
      #
      # @return [void]
      # @api private
      def initialize # :nodoc:
        super
        self.prompt_options = self.class.prompt_options&.deep_dup || {}
        self.embed_options  = self.class.embed_options&.deep_dup  || {}
      end

      # Returns the name of the current agent.
      #
      # This method is also used as a path for view lookup.
      # If this is an anonymous agent, returns "anonymous" instead.
      #
      # @return [String] The agent name or "anonymous" for anonymous agents
      def agent_name
        @agent_name ||= self.class.anonymous? ? "anonymous" : self.class.name.underscore
      end

      # Entry point for action execution.
      # Processes an agent action and instruments it for monitoring.
      #
      # This method wraps the action execution with ActiveSupport::Notifications instrumentation
      # and ensures a Prompt instance is created if no prompt was explicitly called during processing.
      #
      # Actions can be triggered in two ways:
      # - Externally through the public API (e.g., Agent.action_name.generate_now)
      # - Internally through tool calls during AI generation workflows
      #
      # @param method_name [Symbol, String] the name of the action method to process
      # @param args [Array] variable arguments to pass to the action method
      #
      # @return [void]
      def process(method_name, *args, **kwargs) # :nodoc:
        payload = { agent: self.class.name, action: method_name, args:, kwargs: }

        ActiveSupport::Notifications.instrument("process.action_prompt.active_agent", payload) do
          super
        end
      end

      # Applies action-level parameters for prompt generation.
      #
      # This method is called from within an action to apply action-level parameters
      # for the agent. Processing of the parameters is deferred until execution to
      # maximize the context available to the provider.
      #
      # @param new_options [Hash] The parameters to merge into the prompt context
      # @return [void]
      #
      # @example Setting prompt options
      #   def my_action
      #     prompt temperature: 0.8, instructions: "Be creative"
      #   end
      def prompt(new_options = {})
        prompt_options.merge!(new_options)
      end

      # Applies action-level parameters for embedding generation.
      #
      # Similar to prompt() but specifically for embedding operations.
      #
      # @param new_options [Hash] The parameters to merge into the embedding context
      # @return [void]
      #
      # @example Setting embed options
      #   def my_embed_action
      #     embed model: "text-embedding-3-large"
      #   end
      def embed(new_options = {})
        embed_options.merge!(new_options)
      end

      # Executes the prompt using the configured options.
      #
      # This method is the core execution point for prompt generation, triggered by either
      # the +generate_now+ or +generate_later+ workflows.
      #
      # @return [ActiveAgent::Providers::Response] The response from the provider
      # @raise [RuntimeError] If no prompt provider is configured
      #
      # @example
      #   Agent.action.generate_now
      #   # => Generates the prompt and handles the response
      def process_prompt
        fail "Prompt Provider not Configured" unless prompt_provider_klass

        parameters = prompt_options.merge(
          stream_broadcaster:,
          tools_function:,
          instructions: prompt_view_instructions(prompt_options[:instructions])
        ).compact

        prompt_provider_klass.new(**parameters).prompt
      end

      # Executes the embedding using the configured options.
      #
      # This method handles embedding generation using the configured embed provider.
      #
      # @return [ActiveAgent::Providers::Response] The embedding response from the provider
      # @raise [RuntimeError] If no embed provider is configured
      def process_embed
        fail "Embed Provider not Configured" unless embed_provider_klass

        parameters = embed_options.compact

        embed_provider_klass.new(**parameters).embed
      end

      private

      # def handle_response(result)
      #   return result unless result.message.requested_actions.present?

      #   # The assistant message with tool_calls is already added by update_context in the provider
      #   # Now perform the requested actions which will add tool response messages
      #   perform_actions(requested_actions: result.message.requested_actions)

      #   # Continue generation with updated context
      #   process_prompt
      # end

      # Returns the list of action methods available on this agent.
      #
      # Excludes ActiveAgent::Base methods and the current action name.
      #
      # @return [Array<String>] List of action method names
      def action_methods
        super - ActiveAgent::Base.public_instance_methods(false).map(&:to_s) - [ action_name ]
      end



      # Determines the appropriate content type for the prompt.
      #
      # @param prompt_context [Object] The prompt context object
      # @param user_content_type [String, nil] User-specified content type
      # @param class_default [String] Default content type for the class
      # @return [String] The determined content type
      def set_content_type(prompt_context, user_content_type, class_default) # :doc:
        if user_content_type.present?
          user_content_type
        elsif context.multimodal?
          "multipart/mixed"
        elsif prompt_context.body.is_a?(Array)
          prompt_context.content_type || class_default
        end
      end

      # Translates the subject using Rails I18n under [agent_scope, action_name] scope.
      #
      # If no translation is found under the specified scope, defaults to a humanized
      # version of the action name. Supports interpolations for dynamic values.
      #
      # @param interpolations [Hash] Values to interpolate into the translation
      # @return [String] The translated or humanized subject
      def default_i18n_subject(interpolations = {}) # :doc:
        agent_scope = self.class.agent_name.tr("/", ".")
        I18n.t(:subject, **interpolations.merge(scope: [ agent_scope, action_name ], default: action_name.humanize))
      end

      # Applies default values to arguments, computing any Proc values.
      #
      # @param args [Hash] The arguments to apply defaults to
      # @return [Hash] Arguments with defaults applied
      def apply_defaults(args)
        default_values = self.class.default.except(*args.keys).transform_values do |value|
          compute_default(value)
        end

        args.reverse_merge(default_values)
      end

      # Computes the value of a default, executing Procs in the agent context.
      #
      # @param value [Object, Proc] The default value or Proc to compute
      # @return [Object] The computed default value
      def compute_default(value)
        return value unless value.is_a?(Proc)

        if value.arity == 1
          instance_exec(self, &value)
        else
          instance_exec(&value)
        end
      end

      # Assigns arguments to the context object, filtering out reserved keys.
      #
      # @param context [Object] The context object to assign to
      # @param args [Hash] The arguments to assign
      # @return [void]
      def assign_args_to_context(context, args)
        assignable = args.except(:parts_order, :content_type, :body, :role, :template_name,
          :template_path, :delivery_method, :delivery_method_options)

        assignable.each { |k, v| context.send(k, v) if context.respond_to?(k) }
      end



      # Provides instrumentation payload for caching and monitoring.
      #
      # @param key [String] The cache key or operation identifier
      # @return [Hash] Payload hash with agent name and key
      def instrument_payload(key)
        {
          agent: agent_name,
          key: key
        }
      end

      # Returns the instrumentation name for ActiveSupport::Notifications.
      #
      # @return [String] The instrument name "active_agent"
      def instrument_name
        "active_agent"
      end

      # Returns the list of protected instance variables.
      #
      # These variables are not exposed in template contexts for security.
      #
      # @return [Array<String>] List of protected instance variable names
      def _protected_ivars
        PROTECTED_IVARS
      end

      ActiveSupport.run_load_hooks(:active_agent, self)
    end
  end
end
