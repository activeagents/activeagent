require "active_agent/collector"
require "active_support/core_ext/string/inflections"
require "active_support/core_ext/hash/except"
require "active_support/core_ext/module/anonymous"
require "active_agent/action_prompt/message"
require "active_agent/action_prompt/action"

# require "active_agent/log_subscriber"
require "active_agent/rescuable"

require_relative "null_prompt"
require_relative "concerns/provider"

module ActiveAgent
  module ActionPrompt
    class Base < AbstractController::Base
      include Callbacks
      include Provider
      include Streaming
      include QueuedGeneration
      include Rescuable
      include Parameterized
      include Previews
      # include FormBuilder

      abstract!

      include AbstractController::Rendering

      include AbstractController::Logger
      include AbstractController::Helpers
      include AbstractController::Translation
      include AbstractController::AssetPaths
      include AbstractController::Callbacks
      include AbstractController::Caching

      include ActionView::Layouts

      PROTECTED_IVARS = AbstractController::Rendering::DEFAULT_PROTECTED_INSTANCE_VARIABLES + [ :@_action_has_layout ]

      helper ActiveAgent::PromptHelper

      class_attribute :options
      class_attribute :default_params, default: {
        mime_version: "1.0",
        charset: "UTF-8",
        content_type: "text/plain",
        parts_order: [ "text/plain", "text/enriched", "text/html" ]
      }.freeze

      class << self
        # Register one or more Observers which will be notified when prompt is generated.
        def register_observers(*observers)
          observers.flatten.compact.each { |observer| register_observer(observer) }
        end

        # Unregister one or more previously registered Observers.
        def unregister_observers(*observers)
          observers.flatten.compact.each { |observer| unregister_observer(observer) }
        end

        # Register one or more Interceptors which will be called before prompt is sent.
        def register_interceptors(*interceptors)
          interceptors.flatten.compact.each { |interceptor| register_interceptor(interceptor) }
        end

        # Unregister one or more previously registered Interceptors.
        def unregister_interceptors(*interceptors)
          interceptors.flatten.compact.each { |interceptor| unregister_interceptor(interceptor) }
        end

        # Register an Observer which will be notified when prompt is generated.
        # Either a class, string, or symbol can be passed in as the Observer.
        # If a string or symbol is passed in it will be camelized and constantized.
        def register_observer(observer)
          Prompt.register_observer(observer_class_for(observer))
        end

        # Unregister a previously registered Observer.
        # Either a class, string, or symbol can be passed in as the Observer.
        # If a string or symbol is passed in it will be camelized and constantized.
        def unregister_observer(observer)
          Prompt.unregister_observer(observer_class_for(observer))
        end

        # Register an Interceptor which will be called before prompt is sent.
        # Either a class, string, or symbol can be passed in as the Interceptor.
        # If a string or symbol is passed in it will be camelized and constantized.
        def register_interceptor(interceptor)
          Prompt.register_interceptor(observer_class_for(interceptor))
        end

        # Unregister a previously registered Interceptor.
        # Either a class, string, or symbol can be passed in as the Interceptor.
        # If a string or symbol is passed in it will be camelized and constantized.
        def unregister_interceptor(interceptor)
          Prompt.unregister_interceptor(observer_class_for(interceptor))
        end

        def observer_class_for(value) # :nodoc:
          case value
          when String, Symbol
            value.to_s.camelize.constantize
          else
            value
          end
        end
        private :observer_class_for

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
        def generate_with(provider_reference, **agent_options)
          self.provider = provider_reference

          global_options    = provider_config(provider_reference)
          inherited_options = (self.options || {}).except(:instructions) # Don't inherit instructions from parent

          # Different Service, different APIs
          if global_options[:service] != inherited_options[:service]
            inherited_options.extract!(:service, :api_version)
          end

          self.options = global_options.merge(inherited_options).merge(agent_options)
        end

        def stream_with(&stream)
          self.options = (options || {}).merge(stream: stream)
        end

        # Returns the name of the current agent. This method is also being used as a path for a view lookup.
        # If this is an anonymous agent, this method will return +anonymous+ instead.
        def agent_name
          @agent_name ||= anonymous? ? "anonymous" : name.underscore
        end

        # Allows to set the name of current agent.
        attr_writer :agent_name
        alias_method :controller_path, :agent_name

        # Sets the defaults through app configuration:
        #
        #     config.action_agent.default(from: "no-reply@example.org")
        #
        # Aliased by ::default_options=
        def default(value = nil)
          self.default_params = default_params.merge(value).freeze if value
          default_params
        end
        # Allows to set defaults through app configuration:
        #
        #    config.action_agent.default_options = { from: "no-reply@example.org" }
        alias_method :default_options=, :default

        private

        def method_missing(method_name, ...)
          if action_methods.include?(method_name.name)
            Generation.new(self, method_name, ...)
          else
            super
          end
        end

        def respond_to_missing?(method, include_all = false)
          action_methods.include?(method.name) || super
        end
      end

      delegate :agent_name, to: :class

      attr_internal :options # Action-level options merged with agent options

      # @return [void]
      def initialize # :nodoc:
        super
        self.options = self.class.options&.deep_dup
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

        ActiveSupport::Notifications.instrument("process.active_agent", payload) do
          super
        end
      end

      # Applies action-level parameters for the agent.
      #
      # This method is called from within an action to apply action-level parameters
      # for the agent. Processing of the parameters is deferred until execution to
      # maximize the context available to the provider.
      #
      # @param options [Hash] the parameters to merge into the raw context
      # @param block [Proc] optional block for additional processing
      # @return [void]
      def prompt(new_options = {}, &block)
        options.merge!(new_options)
      end

      # Executes the prompt generation using the configured generation provider.
      #
      # This method is the core execution point for prompt generation, triggered by either
      # the +generate_now+ or +generate_later+ workflows.
      #
      # @return [void]
      #
      # @example
      #   Agent.action.generation_now
      #   # => Generates the prompt and handles the response
      #
      def perform_generation
        parameters = options.merge(
          stream_callback:   options[:stream] ? perform_streaming : nil,
          function_callback: options[:tools]  ? perform_tooling   : nil
        ).compact

        provider_klass.new(**parameters).call
      end

      private

      # def handle_response(result)
      #   return result unless result.message.requested_actions.present?

      #   # The assistant message with tool_calls is already added by update_context in the provider
      #   # Now perform the requested actions which will add tool response messages
      #   perform_actions(requested_actions: result.message.requested_actions)

      #   # Continue generation with updated context
      #   perform_generation
      # end

      def perform_streaming
        proc do |message, delta, stop|
          run_stream_callbacks(message, delta, stop) do |message, delta, stop|
            yield message, delta, stop if block_given?
          end
        end
      end

      def perform_tooling
        proc do |action_name, *args, **kwargs|
          process(action_name, *args, **kwargs)
        end
      end

      ###

      def embed
        context.options.merge(options)
        provider_type.embed(context) if context && provider_type
        handle_response(provider_type.response)
      end

      # Add embedding capability to Message class
      ActiveAgent::ActionPrompt::Message.class_eval do
        def embed
          agent_class = ApplicationAgent
          agent = agent_class.new
          agent.context = ActiveAgent::ActionPrompt::Prompt.new(message: self, agent_instance: agent)
          agent.embed
          self
        end
      end

      def update_context(response)
        ActiveAgent::Providers::Response.new(prompt: context)
      end

      def headers(args = nil)
        binding.pry
        if args
          @_context.headers(args)
        else
          @_context
        end
      end

      def prompt_with(*)
        binding.pry
        context.update_context(*)
      end

      # def prompt(args = {}, &block)
      #   return context if @_prompt_was_called && args.blank? && !block

      #   # There are many sins in this function, this input hack is to support raw OpenAI format until prompt resolving
      #   # can be refactored into the context of a provider.
      #   args[:message] ||= args.delete(:input)

      #   # Apply option hierarchy: prompt options > agent options > config options
      #   merged_options = merge_options(args[:options] || {})

      #   raw_instructions = args.has_key?(:instructions) ? args[:instructions] : context.options[:instructions]

      #   context.instructions = prepare_instructions(raw_instructions)

      #   context.options.merge!(merged_options)
      #   context.options[:stream] = perform_stream if context.options[:stream]
      #   content_type = args[:content_type]

      #   args = apply_defaults(args)
      #   context.messages = args[:messages] || []
      #   context.mcp_servers = args[:mcp_servers] || []
      #   context.context_id = args[:context_id]
      #   context.params = params
      #   context.action_name = action_name

      #   context.output_schema = render_schema(args[:output_schema], set_prefixes(args[:output_schema], lookup_context.prefixes))

      #   context.charset = charset = args[:charset]

      #   args = prepare_message(args)
      #   # wrap_generation_behavior!(args[:generation_method], args[:generation_method_options])
      #   # assign_args_to_context(context, args)
      #   responses = collect_responses(args, &block)

      #   @_prompt_was_called = true

      #   create_parts_from_responses(context, responses)

      #   context.content_type = set_content_type(context, content_type, args[:content_type])

      #   context.charset = charset
      #   context.actions = args[:actions] || action_schemas

      #   context
      # end

      def action_methods
        super - ActiveAgent::Base.public_instance_methods(false).map(&:to_s) - [ action_name ]
      end

      def action_schemas
        prefixes = set_prefixes(action_name, lookup_context.prefixes)

        action_methods.map do |action|
          render_schema(action, prefixes)
        end.compact
      end

      def prepare_message(args)
        if args[:message].present?
          case args[:message]
          when Hash # RIP Switch Cascading
            message = ActiveAgent::ActionPrompt::Message.new(args[:message])
            args[:body] = message.content
            args[:role] = message.role
          when ActiveAgent::ActionPrompt::Message
            args[:body] = args[:message].content
            args[:role] = args[:message].role
          when Array, String
            # Handle array of multipart content like [{type: "text", text: "..."}, {type: "file", file: {...}}]
            args[:body] = args[:message]
            args[:role] = :user
          end
        end
        load_input_data(args)

        args
      end

      def load_input_data(args)
        if args[:image_data].present?
          args[:body] = [
            ActiveAgent::ActionPrompt::Message.new(content: args[:image_data], content_type: "image_data"),
            ActiveAgent::ActionPrompt::Message.new(content: args[:body], content_type: "input_text")
          ]
        elsif args[:file_data].present?
          args[:body] = [
            ActiveAgent::ActionPrompt::Message.new(content: args[:file_data], metadata: { filename: "resume.pdf" }, content_type: "file_data"),
            ActiveAgent::ActionPrompt::Message.new(content: args[:body], content_type: "input_text")
          ]
        end
        args
      end

      def set_prefixes(action, prefixes)
        prefixes = lookup_context.prefixes | [ self.class.agent_name ]
      end

      def render_schema(schema_or_action, prefixes)
        # If it's already a hash (direct schema), return it
        return schema_or_action if schema_or_action.is_a?(Hash)

        # Otherwise try to load from template
        return unless lookup_context.template_exists?(schema_or_action, prefixes, false, formats: [ :json ])

        JSON.parse render_to_string(locals: { action_name: schema_or_action }, action: schema_or_action, formats: :json)
      end

      def set_content_type(prompt_context, user_content_type, class_default) # :doc:
        if user_content_type.present?
          user_content_type
        elsif context.multimodal?
          "multipart/mixed"
        elsif prompt_context.body.is_a?(Array)
          prompt_context.content_type || class_default
        end
      end

      # Translates the +subject+ using \Rails I18n class under <tt>[agent_scope, action_name]</tt> scope.
      # If it does not find a translation for the +subject+ under the specified scope it will default to a
      # humanized version of the <tt>action_name</tt>.
      # If the subject has interpolations, you can pass them through the +interpolations+ parameter.
      def default_i18n_subject(interpolations = {}) # :doc:
        agent_scope = self.class.agent_name.tr("/", ".")
        I18n.t(:subject, **interpolations.merge(scope: [ agent_scope, action_name ], default: action_name.humanize))
      end

      def apply_defaults(args)
        default_values = self.class.default.except(*args.keys).transform_values do |value|
          compute_default(value)
        end

        args.reverse_merge(default_values)
      end

      def compute_default(value)
        return value unless value.is_a?(Proc)

        if value.arity == 1
          instance_exec(self, &value)
        else
          instance_exec(&value)
        end
      end

      def assign_args_to_context(context, args)
        assignable = args.except(:parts_order, :content_type, :body, :role, :template_name,
          :template_path, :delivery_method, :delivery_method_options)

        assignable.each { |k, v| context.send(k, v) if context.respond_to?(k) }
      end

      def collect_responses(args, &)
        if block_given?
          collect_responses_from_block(args, &)
        elsif args[:body]
          collect_responses_from_text(args)
        else
          collect_responses_from_templates(args)
        end
      end

      def collect_responses_from_block(args)
        templates_name = args[:template_name] || action_name
        collector = ActiveAgent::Collector.new(lookup_context) { render(templates_name) }
        yield(collector)
        collector.responses
      end

      def collect_responses_from_text(args)
        [ {
          body: args.delete(:body),
          content_type: args[:content_type] || "text/plain"
        } ]
      end

      def collect_responses_from_templates(args)
        templates_path = args[:template_path] || self.class.agent_name
        templates_name = args[:template_name] || action_name
        each_template(Array(templates_path), templates_name).map do |template|
          next if template.format == :json && args[:format] != :json
          format = template.format || formats.first
          {
            body: render(template: template, formats: [ format ]),
            content_type: Mime[format].to_s
          }
        end.compact
      end

      def each_template(paths, name, &)
        templates = lookup_context.find_all(name, paths)
        if templates.empty?
          raise ActionView::MissingTemplate.new(paths, name, paths, false, "agent")
        else
          templates.uniq(&:format).each(&)
        end
      end

      def create_parts_from_responses(context, responses)
        if responses.size > 1
          responses.each { |r| insert_part(context, r, context.charset) }
        else
          responses.each { |r| insert_part(context, r, context.charset) }
        end
      end

      def insert_part(context, response, charset)
        message = ActiveAgent::ActionPrompt::Message.new(
          content: response[:body],
          content_type: response[:content_type],
          charset: charset
        )
        context.add_part(message)
      end

      def prepare_instructions(instructions)
        case instructions
        when Hash
          raise ArgumentError, "Expected `:template` key in instructions hash" unless instructions[:template]
          return unless lookup_context.exists?(instructions[:template], agent_name, false, [], formats: [ :text ])

          template = lookup_context.find_template(instructions[:template], agent_name, false, [], formats: [ :text ])
          render_to_string(template: template.virtual_path, locals: instructions[:locals] || {}, layout: false)
        when String
          instructions
        when NilClass
          default_template_name = "instructions"
          return unless lookup_context.exists?(default_template_name, agent_name, false, [], formats: [ :text ])

          template = lookup_context.find_template(default_template_name, agent_name, false, [], formats: [ :text ])
          render_to_string(template: template.virtual_path, layout: false)
        else
          raise ArgumentError, "Instructions must be Hash, String or NilClass objects"
        end
      end

      # This and #instrument_name is for caching instrument
      def instrument_payload(key)
        {
          agent: agent_name,
          key: key
        }
      end

      def instrument_name
        "active_agent"
      end

      def _protected_ivars
        PROTECTED_IVARS
      end

      ActiveSupport.run_load_hooks(:active_agent, self)
    end
  end
end
