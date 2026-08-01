# frozen_string_literal: true

module ActiveAgent
  # Per-model capability quirks, applied before a request reaches the
  # provider. Vendors ship models that reject otherwise-standard sampling
  # parameters (thinking-first models steered by prompting/effort instead)
  # with an API 400 — this registry strips those parameters up front so an
  # agent configured with a shared temperature keeps working across model
  # switches.
  #
  # The built-in rules cover the known families; apps can extend the
  # registry for new or self-hosted models:
  #
  # @example Register a custom rule
  #   ActiveAgent::ModelCapabilities.register(/\Amy-reasoning-model/, unsupported: [:temperature, :top_p])
  #
  # @example Disable sanitization entirely
  #   ActiveAgent::ModelCapabilities.enabled = false
  module ModelCapabilities
    SAMPLING_PARAMS = [ :temperature, :top_p ].freeze

    # Model families that reject sampling parameters with a 400:
    # - Anthropic thinking-first models (Opus 4.7+, Opus 5, Sonnet 5,
    #   Fable 5 / Mythos 5)
    # - OpenAI reasoning models (o-series, GPT-5 family)
    BUILTIN_RULES = [
      { pattern: /\Aclaude-(opus-5|opus-4-[78]|sonnet-5|fable-5|mythos-5)/, unsupported: SAMPLING_PARAMS },
      { pattern: /\A(o1|o3|o4)(-|$)/, unsupported: SAMPLING_PARAMS },
      { pattern: /\Agpt-5/, unsupported: SAMPLING_PARAMS }
    ].freeze

    class << self
      # Master switch; on by default. Set false to send parameters through
      # untouched (the vendor then enforces its own rules).
      attr_writer :enabled

      def enabled
        return @enabled unless @enabled.nil?

        true
      end

      # Registers an app-defined capability rule ahead of the built-ins.
      #
      # @param pattern [Regexp] matched against the model name
      # @param unsupported [Array<Symbol>] parameter keys the model rejects
      def register(pattern, unsupported:)
        custom_rules << { pattern: pattern, unsupported: unsupported.map(&:to_sym) }
      end

      def custom_rules
        @custom_rules ||= []
      end

      def reset!
        @custom_rules = []
        @enabled = nil
      end

      # @return [Array<Symbol>] parameter keys the model rejects
      def unsupported_params(model)
        return [] if model.nil?

        (custom_rules + BUILTIN_RULES).each do |rule|
          return rule[:unsupported] if model.to_s.match?(rule[:pattern])
        end
        []
      end

      def sampling_supported?(model)
        (unsupported_params(model) & SAMPLING_PARAMS).empty?
      end

      # Strips parameters the model rejects, in place. Returns the removed
      # keys (empty when nothing applied).
      #
      # @param parameters [Hash] prepared prompt parameters (must carry :model)
      # @return [Array<Symbol>] removed parameter keys
      def sanitize!(parameters)
        return [] unless enabled
        return [] unless parameters.is_a?(Hash)

        removed = unsupported_params(parameters[:model]).select { |key| parameters.key?(key) }
        removed.each { |key| parameters.delete(key) }
        removed
      end
    end
  end
end
