require "active_agent/collector"
require "active_support/core_ext/string/inflections"
require "active_support/core_ext/hash/except"
require "active_support/core_ext/module/anonymous"

# require "active_agent/log_subscriber"
require "active_agent/rescuable"
module ActiveAgent
  module ActionPrompt
    class Base < AbstractController::Base
      include Callbacks
      include GenerationMethods
      include GenerationProvider
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
        def generate_with(provider, **options)
          self.generation_provider = provider
          self.options = (options || {}).merge(options)
          self.options[:stream] = new.agent_stream if self.options[:stream]
          generation_provider.config.merge!(self.options)
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

        # Wraps a prompt generation inside of ActiveSupport::Notifications instrumentation.
        #
        # This method is actually called by the +ActionPrompt::Prompt+ object itself
        # through a callback when you call <tt>:generate_prompt</tt> on the +ActionPrompt::Prompt+,
        # calling +generate_prompt+ directly and passing an +ActionPrompt::Prompt+ will do
        # nothing except tell the logger you generated the prompt.
        def generate_prompt(prompt) # :nodoc:
          ActiveSupport::Notifications.instrument("deliver.active_agent") do |payload|
            set_payload_for_prompt(payload, prompt)
            yield # Let Prompt do the generation actions
          end
        end

        private

        def set_payload_for_prompt(payload, prompt)
          payload[:prompt] = prompt.encoded
          payload[:agent] = agent_name
          payload[:message_id] = prompt.message_id
          payload[:date] = prompt.date
          payload[:perform_generations] = prompt.perform_generations
        end

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

      attr_internal :context

      def agent_stream
        proc do |message, delta, stop|
          run_stream_callbacks(message, delta, stop) do |message, delta, stop|
            yield message, delta, stop if block_given?
          end
        end
      end

      def embed
        context.options.merge(options)
        generation_provider.embed(context) if context && generation_provider
        handle_response(generation_provider.response)
      end

      # Add embedding capability to Message class
      ActiveAgent::ActionPrompt::Message.class_eval do
        def embed
          agent_class = ActiveAgent::Base.descendants.first
          agent = agent_class.new
          agent.context = ActiveAgent::ActionPrompt::Prompt.new(message: self)
          agent.embed
          self
        end
      end

      # Make context accessible for chaining
      # attr_accessor :context

      def perform_generation
        generation_provider.generate(context) if context && generation_provider
        handle_response(generation_provider.response)
      end

      def handle_response(response)
        return response unless response.message.requested_actions.present?
        perform_actions(requested_actions: response.message.requested_actions)
        update_context(response)
      end

      def update_context(response)
        context.message = context.messages.last
        ActiveAgent::GenerationProvider::Response.new(prompt: context)
      end

      def perform_actions(requested_actions:)
        requested_actions.each do |action|
          perform_action(action)
        end
      end

      def perform_action(action)
        current_context = context.clone
        process(action.name, *action.params)
        context.messages.last.role = :tool
        context.messages.last.action_id = action.id
        context.messages.last.action_name = action.name
        context.messages.last.generation_id = action.id
        current_context.messages << context.messages.last
        self.context = current_context
      end

      def initialize
        super
        @_prompt_was_called = false
        @_context = ActiveAgent::ActionPrompt::Prompt.new(instructions: options[:instructions], options: options)
      end

      def process(method_name, *args) # :nodoc:
        payload = {
          agent: self.class.name,
          action: method_name,
          args: args
        }

        ActiveSupport::Notifications.instrument("process.active_agent", payload) do
          super
          @_context = ActiveAgent::ActionPrompt::Prompt.new unless @_prompt_was_called
        end
      end
      ruby2_keywords(:process)

      class NullPrompt # :nodoc:
        def message
          ""
        end

        def header
          {}
        end

        def respond_to?(string, include_all = false)
          true
        end

        def method_missing(...)
          nil
        end
      end

      # Returns the name of the agent object.
      def agent_name
        self.class.agent_name
      end

      def headers(args = nil)
        if args
          @_context.headers(args)
        else
          @_context
        end
      end

      def prompt_with(*)
        context.update_context(*)
      end

      def prompt(headers = {}, &block)
        return context if @_prompt_was_called && headers.blank? && !block

        context.options.merge!(options)
        content_type = headers[:content_type]
        headers = apply_defaults(headers)
        context.messages = headers[:messages] || []
        context.context_id = headers[:context_id]
        context.params = params

        context.charset = charset = headers[:charset]

        if headers[:message].present? && headers[:message].is_a?(ActiveAgent::ActionPrompt::Message)
          headers[:body] = headers[:message].content
          headers[:role] = headers[:message].role
        elsif headers[:message].present? && headers[:message].is_a?(String)
          headers[:body] = headers[:message]
          headers[:role] = :user
        end

        # wrap_generation_behavior!(headers[:generation_method], headers[:generation_method_options])
        # assign_headers_to_context(context, headers)
        responses = collect_responses(headers, &block)

        @_prompt_was_called = true

        create_parts_from_responses(context, responses)

        context.content_type = set_content_type(context, content_type, headers[:content_type])
        context.charset = charset
        context.actions = headers[:actions] || action_schemas

        if (action_methods - ActiveAgent::Base.descendants.first.action_methods).include? action_name
          context.actions = (action_methods - [ action_name ])
        end

        context
      end

      def action_methods
        super - ActiveAgent::Base.public_instance_methods(false).map(&:to_s)
      end

      def action_schemas
        action_methods.map do |action|
          next unless lookup_context.exists?(action, self.class.agent_name, true, formats: [:json])

          JSON.parse render_to_string(locals: { action_name: action }, action: action, formats: :json)
        end.compact
      end

      private

      def set_content_type(m, user_content_type, class_default) # :doc:
        if user_content_type.present?
          user_content_type
        else
          context.content_type || class_default
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

      def apply_defaults(headers)
        default_values = self.class.default.except(*headers.keys).transform_values do |value|
          compute_default(value)
        end

        headers.reverse_merge(default_values)
      end

      def compute_default(value)
        return value unless value.is_a?(Proc)

        if value.arity == 1
          instance_exec(self, &value)
        else
          instance_exec(&value)
        end
      end

      def assign_headers_to_context(context, headers)
        assignable = headers.except(:parts_order, :content_type, :body, :role, :template_name,
          :template_path, :delivery_method, :delivery_method_options)

        assignable.each { |k, v| context.send(k, v) if context.respond_to?(k) }
      end

      def collect_responses(headers, &)
        if block_given?
          collect_responses_from_block(headers, &)
        elsif headers[:body]
          collect_responses_from_text(headers)
        else
          collect_responses_from_templates(headers)
        end
      end

      def collect_responses_from_block(headers)
        templates_name = headers[:template_name] || action_name
        collector = ActiveAgent::Collector.new(lookup_context) { render(templates_name) }
        yield(collector)
        collector.responses
      end

      def collect_responses_from_text(headers)
        [ {
          body: headers.delete(:body),
          content_type: headers[:content_type] || "text/plain"
        } ]
      end

      def collect_responses_from_templates(headers)
        templates_path = headers[:template_path] || self.class.agent_name
        templates_name = headers[:template_name] || action_name

        each_template(Array(templates_path), templates_name).map do |template|
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
          # prompt_container = ActiveAgent::ActionPrompt::Prompt.new
          # prompt_container.content_type = "multipart/alternative"
          responses.each { |r| insert_part(context, r, context.charset) }
          # context.add_part(prompt_container)
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
