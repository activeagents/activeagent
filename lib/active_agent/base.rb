# frozen_string_literal: true

require "active_support/core_ext/hash/except"
require "active_support/core_ext/module/anonymous"
require "active_support/core_ext/string/inflections"

require "active_agent/concerns/callbacks"
require "active_agent/concerns/observers"
require "active_agent/concerns/parameterized"
require "active_agent/concerns/preview"
require "active_agent/concerns/provider"
require "active_agent/concerns/queueing"
require "active_agent/concerns/rescue"
require "active_agent/concerns/streaming"
require "active_agent/concerns/tooling"
require "active_agent/concerns/view"

require "active_agent/providers/log_subscriber"

module ActiveAgent
  # Base class for creating AI-powered agents with prompt generation, tool calling,
  # and conversation management.
  #
  # Extends AbstractController::Base with AI-specific functionality including provider
  # management, streaming, and tooling capabilities.
  #
  # @example Basic agent
  #   class MyAgent < ActiveAgent::Base
  #     generate_with :openai, model: "gpt-4"
  #
  #     def greet
  #       prompt instructions: "Greet the user warmly"
  #     end
  #   end
  #
  # @abstract
  class Base < AbstractController::Base
    abstract!

    include AbstractController::Rendering
    include AbstractController::Logger
    include AbstractController::Helpers
    include AbstractController::Translation
    include AbstractController::AssetPaths
    include AbstractController::Callbacks
    include AbstractController::Caching

    include Callbacks
    include Parameterized
    include Provider
    include Queueing
    include Rescue
    include Streaming
    include Tooling
    include View

    include Observers
    include Previews

    PROTECTED_IVARS = AbstractController::Rendering::DEFAULT_PROTECTED_INSTANCE_VARIABLES + [ :@_action_has_layout ]

    # Logger instance conforming to Log4r or Ruby Logger interface.
    #
    # Defaults to Rails.logger when used in Rails applications.
    #
    # @return [Logger, nil]
    cattr_accessor :logger

    class_attribute :prompt_options
    class_attribute :embed_options

    class << self
      class_attribute :default_params, default: {
        mime_version: "1.0",
        charset: "UTF-8",
        content_type: "text/plain",
        parts_order: [ "text/markdown", "text/plain", "text/enriched", "text/html" ]
      }.freeze

      # Sets default parameters applied to all actions unless overridden.
      #
      # @param value [Hash, nil] parameters to merge, or nil to return current defaults
      # @return [Hash]
      #
      # @example
      #   default temperature: 0.7, max_tokens: 1000
      def default(value = nil)
        self.default_params = default_params.merge(value).freeze if value
        default_params
      end
      alias_method :default_params=, :default
    end

    # Configures the generation provider and options for prompt generation.
    #
    # Specifies the AI provider and shared configuration options across all actions.
    # Options are merged with global provider config and inherited options.
    #
    # @param provider_reference [Symbol, String] generation provider (:openai, :anthropic, etc.)
    # @param agent_options [Hash] configuration options shared across actions
    # @return [void]
    #
    # @example
    #   generate_with :openai, model: "gpt-4", temperature: 0.7
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
    # @param provider_reference [Symbol, String] embedding provider (:openai, :anthropic, etc.)
    # @param agent_options [Hash] configuration options for embedding generation
    # @return [void]
    #
    # @example
    #   embed_with :openai, model: "text-embedding-3-large"
    def self.embed_with(provider_reference, **agent_options)
      self.embed_provider = provider_reference

      global_options    = provider_config_load(provider_reference)
      inherited_options = self.embed_options || {}

      self.embed_options = global_options.merge(inherited_options).merge(agent_options)
    end

    # @api private
    def self.method_missing(method_name, ...)
      if action_methods.include?(method_name.name)
        Generation.new(self, method_name, ...)
      else
        super
      end
    end
    private_class_method :method_missing

    # @api private
    def self.respond_to_missing?(method, include_all = false)
      action_methods.include?(method.name) || super
    end
    private_class_method :respond_to_missing?

    delegate :agent_name, to: :class

    attr_writer :agent_name
    alias_method :controller_path, :agent_name

    # Action-level prompt options merged with agent prompt options.
    # @return [Hash]
    attr_internal :prompt_options

    # Action-level embed options merged with agent embed options.
    # @return [Hash]
    attr_internal :embed_options

    # @api private
    def initialize # :nodoc:
      super
      self.prompt_options = (self.class.prompt_options&.deep_dup || {}).except(:trace_id)
      self.embed_options  = (self.class.embed_options&.deep_dup  || {}).except(:trace_id)
    end

    # Returns the agent name used as a path for view lookup.
    #
    # @return [String] agent name or "anonymous" for anonymous agents
    def agent_name
      @agent_name ||= self.class.anonymous? ? "anonymous" : self.class.name.underscore
    end

    # Processes an agent action with ActiveSupport::Notifications instrumentation.
    #
    # Actions can be triggered externally (Agent.action_name.generate_now) or internally
    # through tool calls during AI generation workflows.
    #
    # @param method_name [Symbol, String] action method to process
    # @param args [Array]
    # @param kwargs [Hash]
    # @return [void]
    def process(method_name, *args, **kwargs) # :nodoc:
      payload = { agent: self.class.name, action: method_name, args:, kwargs: }

      ActiveSupport::Notifications.instrument("process.active_agent", payload) do
        super
      end
    end

    # Merges action-level parameters into the prompt context.
    #
    # Call from within an action to apply action-specific parameters.
    # Processing is deferred until execution to maximize available context.
    #
    # @param messages [Array] message strings or hashes to add to conversation
    # @param options [Hash] parameters to merge into prompt context
    # @return [void]
    #
    # @example
    #   def my_action
    #     prompt "User message", temperature: 0.8, instructions: "Be creative"
    #   end
    def prompt(*messages, **options)
      # Extract message/messages from options and add to messages array
      messages += options.extract!(:message, :messages).values.flatten.compact

      # Extract image and document attachments
      messages += options.extract!(:image, :document).map { |k, v| { k => v } }

      prompt_options.merge!({ messages: }.compact_blank.merge!(options))
    end

    # Merges action-level parameters into the embedding context.
    #
    # @param input [String, Array<String>, nil] text to embed
    # @param options [Hash] parameters to merge into embedding context
    # @return [void]
    #
    # @example With direct input
    #   embed "Text to embed", model: "text-embedding-3-large"
    #
    # @example With template
    #   embed locals: { text: "Custom text" }
    def embed(input = nil, **options)
      new_options = { input: }.compact_blank.merge!(options)
      embed_options.merge!(new_options)
    end

    # Executes prompt generation using the configured provider and options.
    #
    # Core execution point triggered by generate_now or generate_later workflows.
    # Renders templates as late as possible to allow local overrides.
    #
    # @return [ActiveAgent::Providers::Response]
    # @raise [RuntimeError] if no prompt provider is configured
    def process_prompt
      fail "Prompt Provider not Configured" unless prompt_provider_klass

      parameters = prompt_options.except(:locals)

      # Render out proc/lamda attributes before rendering templates
      parameters.deep_transform_values! { it.respond_to?(:call) ? it.call : it }

      # Apply Callbacks
      parameters.merge!(
        trace_id: prompt_options[:trace_id] || SecureRandom.uuid,
        exception_handler:,
        stream_broadcaster:,
        tools_function:,
        instructions: prompt_view_instructions(prompt_options[:instructions])
      ).compact!

      # Fallback to message from template if no messages provided, rendered as late as
      # possible to allow local overrides.
      if parameters[:messages].blank?
        template_message = prompt_view_message(action_name, **prompt_options[:locals])
        parameters[:messages] = [ template_message ] if template_message.present?
      end

      prompt_provider_klass.new(**parameters).prompt
    end

    # Executes prompt generation with exception handling (bang version).
    #
    # This is an alias for process_prompt that may be used in contexts
    # where exception handling behavior differs.
    #
    # @return [ActiveAgent::Providers::Response]
    # @raise [RuntimeError] if no prompt provider is configured
    def process_prompt!
      process_prompt
    end

    # Executes embedding generation using the configured provider and options.
    #
    # Renders templates as late as possible to allow local overrides.
    #
    # @return [ActiveAgent::Providers::Response]
    # @raise [RuntimeError] if no embed provider is configured
    def process_embed
      fail "Embed Provider not Configured" unless embed_provider_klass

      parameters = embed_options.except(:locals)

      # Render out proc/lamda attributes before rendering templates
      parameters.deep_transform_values! { it.respond_to?(:call) ? it.call : it }

      # Apply Callbacks
      parameters.merge!(
        trace_id: prompt_options[:trace_id] || SecureRandom.uuid,
        exception_handler:
      ).compact!

      # Fallback to input from template if no input provided, rendered as late as
      # possible to allow local overrides.
      if parameters[:input].blank?
        template_input = embed_view_input(action_name, **embed_options[:locals])
        parameters[:input] = template_input if template_input.present?
      end

      embed_provider_klass.new(**parameters).embed
    end

    # @return [Array<String>]
    def action_methods
      super - ActiveAgent::Base.public_instance_methods(false).map(&:to_s) - [ action_name ]
    end

    private

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

    # @return [Array<String>]
    def _protected_ivars
      PROTECTED_IVARS
    end

    ActiveSupport.run_load_hooks(:active_agent, self)
  end
end
