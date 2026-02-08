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
  # Provides AI-powered agents with prompt generation, tool calling, and conversation management.
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

    PROTECTED_OPTIONS = %i[exception_handler stream_broadcaster tools_function]
    PROTECTED_IVARS = AbstractController::Rendering::DEFAULT_PROTECTED_INSTANCE_VARIABLES + [ :@_action_has_layout ]

    # Logger instance for agent operations.
    #
    # Defaults to Rails.logger when used in Rails applications.
    # Must conform to Log4r or Ruby Logger interface.
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

    # Configures generation provider and options for prompt generation.
    #
    # Options are merged with global provider config and inherited parent class options.
    # Instructions are never inherited from parent classes.
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

      # Different Service, different APIs — discard all inherited options
      # to prevent parent provider config (host, api_key, etc.) leaking through
      if global_options[:service] != inherited_options[:service]
        inherited_options = {}
      end

      self.prompt_options = global_options.merge(inherited_options).merge(agent_options)
    end

    # Configures embedding provider and options for embedding generation.
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

    # @!attribute [w] agent_name
    # Agent name override for custom view lookup paths.
    # @return [String]
    attr_writer :agent_name
    alias_method :controller_path, :agent_name

    # @!attribute [rw] prompt_options
    # Action-level prompt options merged with agent prompt options.
    # @return [Hash]
    attr_internal :prompt_options

    # @!attribute [rw] embed_options
    # Action-level embed options merged with agent embed options.
    # @return [Hash]
    attr_internal :embed_options

    # @api private
    def initialize # :nodoc:
      super
      self.prompt_options = (self.class.prompt_options&.deep_dup || {}).except(:trace_id)
      self.embed_options  = (self.class.embed_options&.deep_dup  || {}).except(:trace_id)
    end

    # Agent name used as a path for view lookup.
    #
    # @return [String] agent name or "anonymous" for anonymous agents
    def agent_name
      @agent_name ||= self.class.anonymous? ? "anonymous" : self.class.name.underscore
    end

    # Processes an agent action with ActiveSupport::Notifications instrumentation.
    #
    # Actions are triggered externally via Agent.action_name.generate_now or internally
    # through tool calls during AI generation workflows.
    #
    # @param method_name [Symbol, String] action method to process
    # @param args [Array]
    # @param kwargs [Hash]
    # @return [void]
    # @api private
    def process(method_name, *args, **kwargs)
      payload = { agent: self.class.name, action: method_name, args:, kwargs: }

      ActiveSupport::Notifications.instrument("process.active_agent", payload) do
        super
      end
    end

    # Merges action-level parameters into prompt context.
    #
    # Processing is deferred until execution to allow local overrides.
    #
    # @param messages [Array<String, Hash>] message strings or hashes to add to conversation
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

    # Merges action-level parameters into embedding context.
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

    # Executes prompt generation using configured provider and options.
    #
    # Triggered by generate_now or generate_later workflows. Templates are
    # rendered as late as possible to allow local overrides.
    #
    # @return [ActiveAgent::Providers::Response]
    # @raise [RuntimeError] if no prompt provider is configured
    def process_prompt
      fail "Prompt Provider not Configured" unless prompt_provider_klass

      run_callbacks(:generation) do
        run_callbacks(:prompting) do
          parameters = prepare_prompt_parameters

          prompt_provider_klass.new(**parameters).prompt
        end
      end
    end

    alias_method :process_prompt!, :process_prompt

    # Generates a preview of the prompt without executing generation.
    #
    # Useful for debugging and inspecting the final prompt that would be
    # sent to the provider, including rendered templates and merged parameters.
    #
    # @return [String, Hash] preview format depends on provider implementation
    # @raise [RuntimeError] if no prompt provider is configured
    def preview_prompt
      fail "Prompt Provider not Configured" unless prompt_provider_klass

      parameters = prepare_prompt_parameters

      prompt_provider_klass.new(**parameters).preview
    end

    # Executes embedding generation using configured provider and options.
    #
    # Templates are rendered as late as possible to allow local overrides.
    #
    # @return [ActiveAgent::Providers::Response]
    # @raise [RuntimeError] if no embed provider is configured
    def process_embed
      fail "Embed Provider not Configured" unless embed_provider_klass

      run_callbacks(:generation) do
        run_callbacks(:embedding) do
          parameters = prepare_embed_parameters

          embed_provider_klass.new(**parameters).embed
        end
      end
    end

    # @api private
    def action_methods
      super - ActiveAgent::Base.public_instance_methods(false).map(&:to_s) - [ action_name ]
    end

    private

    # @api private
    def prepare_prompt_parameters
      parameters = prompt_options.deep_dup.except(:locals, *PROTECTED_OPTIONS)

      # Render out proc/lamda attributes before rendering templates
      parameters.deep_transform_values! { _1.respond_to?(:call) ? _1.call : _1 }

      # Apply Callbacks
      parameters.merge!(
        trace_id: prompt_options[:trace_id] || SecureRandom.uuid,
        exception_handler:,
        stream_broadcaster:,
        tools_function:,
      )

      # Apply Templates
      parameters = process_prompt_templates(parameters, prompt_options)

      parameters.compact
    end

    # @api private
    def prepare_embed_parameters
      parameters = embed_options.deep_dup.except(:locals, *PROTECTED_OPTIONS)

      # Render out proc/lamda attributes before rendering templates
      parameters.deep_transform_values! { _1.respond_to?(:call) ? _1.call : _1 }

      # Apply Callbacks
      parameters.merge!(
        trace_id: prompt_options[:trace_id] || SecureRandom.uuid,
        exception_handler:
      ).compact!

      # Fallback to input from template if no input provided, rendered as late as
      # possible to allow local overrides.
      if parameters[:input].blank?
        template_input = embed_view_input(action_name, strict: true, **(embed_options[:locals] || {}))
        parameters[:input] = template_input if template_input.present?
      end

      parameters.compact
    end

    # @api private
    def process_prompt_templates(parameters, prompt_options)
      # Resolve Instructions
      parameters[:instructions] = prompt_view_instructions(parameters[:instructions])

      # Resolve Message Template as fallback
      if (parameters[:messages] || parameters[:input]).blank?
        template_message = prompt_view_message(action_name, strict: parameters[:instructions].blank?, **(prompt_options[:locals] || {}))
        parameters[:messages] = [ template_message ] if template_message.present?
      end

      # Resolve Response Format
      if parameters[:response_format]
        parameters[:response_format] = process_prompt_templates_response_format(parameters[:response_format])
      end

      parameters
    end

    # @api private
    def process_prompt_templates_response_format(response_format)
      if response_format.is_a?(Symbol) || response_format.is_a?(String)
        response_format = { type: response_format.to_s }
      end

      if response_format[:type].to_sym == :json_schema
        response_format[:json_schema] = prompt_view_schema(response_format[:json_schema])
        response_format[:json_schema].deep_transform_keys! { _1.to_s.camelize(:lower) }
      end

      response_format
    end

    # @api private
    def instrument_payload(key)
      {
        agent: agent_name,
        key: key
      }
    end

    # @api private
    def instrument_name
      "active_agent"
    end

    # @api private
    def _protected_ivars
      PROTECTED_IVARS
    end

    ActiveSupport.run_load_hooks(:active_agent, self)
  end
end
