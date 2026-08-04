# frozen_string_literal: true

module ActiveAgent
  module Delegation
    # The provider and options a delegated call runs against.
    #
    # A sub-agent's contract — what it accepts, what it returns — is separate
    # from what actually serves it. Backend is that seam: the same
    # +SummarizerAgent+ can run on a cheap local model inside one parent and on
    # a frontier model inside another, and neither parent's code changes when
    # you move it.
    #
    # @example Swap the model, keep the provider
    #   delegate_to SummarizerAgent, backend: { model: "gpt-4o-mini", temperature: 0 }
    #
    # @example Swap the provider entirely
    #   delegate_to SummarizerAgent, backend: :ollama
    #
    # @example Swap both
    #   delegate_to SummarizerAgent, backend: { provider: :anthropic, model: "claude-haiku-4-5" }
    class Backend
      # @return [Symbol, nil] provider reference (+:openai+, +:anthropic+, ...)
      attr_reader :provider
      # @return [Hash] prompt options applied at the call site
      attr_reader :options

      # @param spec [Backend, Symbol, String, Hash, nil]
      # @return [Backend]
      def self.build(spec = nil)
        case spec
        when Backend        then spec
        when nil            then new
        when Symbol, String then new(provider: spec)
        when Hash           then new(**spec.symbolize_keys)
        else
          raise ArgumentError, "Delegation backend must be a Symbol, Hash or #{name}, got #{spec.inspect}"
        end
      end

      # @param provider [Symbol, String, nil]
      # @param options [Hash] prompt options (model, temperature, ...)
      def initialize(provider: nil, **options)
        @provider = provider&.to_sym
        @options  = options
        @mutex    = Mutex.new
      end

      # @return [Boolean] whether this backend changes anything
      def overrides?
        provider.present? || options.any?
      end

      # Resolves the class a delegated call should instantiate.
      #
      # Swapping providers means rebuilding provider configuration (host, keys,
      # service), not just merging a hash — so the swap goes through a cached
      # subclass configured by +generate_with+, the same code path a
      # hand-written agent takes. The subclass reports its parent's name so
      # template lookup keeps resolving to the original agent's views.
      #
      # @param agent_class [Class] the declared sub-agent class
      # @return [Class]
      def agent_class_for(agent_class)
        return agent_class if provider.blank?

        @mutex.synchronize do
          @agent_classes ||= {}
          @agent_classes[agent_class] ||= build_agent_class(agent_class)
        end
      end

      # Applies call-site options to a prepared agent instance.
      #
      # Applied after the action has run so the delegation site wins over the
      # sub-agent's own +prompt+ options — a call-site override is runtime
      # configuration, which outranks class configuration everywhere else in
      # ActiveAgent.
      #
      # @param agent [ActiveAgent::Base]
      # @return [ActiveAgent::Base]
      def apply(agent)
        agent.prompt_options.merge!(options) if options.any?
        agent
      end

      # @return [Hash]
      def to_h
        { provider: provider }.compact.merge(options)
      end

      private

      # @param agent_class [Class]
      # @return [Class]
      def build_agent_class(agent_class)
        backend_provider = provider
        inherited_name   = agent_class.name

        Class.new(agent_class) do
          # Keep the parent's identity so `agent_name`, and therefore view
          # lookup, resolves to the original agent's templates.
          define_singleton_method(:name) { inherited_name }

          generate_with backend_provider
        end
      end
    end
  end
end
