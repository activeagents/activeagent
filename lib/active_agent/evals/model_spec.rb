# frozen_string_literal: true

module ActiveAgent
  module Evals
    # A candidate model for a comparison run, resolved from the string a user
    # types. `label` is that string verbatim and keys the model's cohort in a
    # report; `provider` and `model` are what the run executes under:
    #
    #   "anthropic/claude-sonnet-5"       → anthropic, claude-sonnet-5
    #   "claude-haiku-4-5"                → anthropic (inferred), claude-haiku-4-5
    #   "gpt-5-mini"                      → openai (inferred), gpt-5-mini
    #   "qwen3:8b"                        → ollama (inferred from the tag), qwen3:8b
    #   "meta-llama/llama-3.3-70b"        → openrouter, meta-llama/llama-3.3-70b
    #   "openrouter/anthropic/claude-3"   → openrouter, anthropic/claude-3
    #
    # `providers` lists the names a leading path segment may name; a vendor
    # prefix that is not one of them routes through openrouter when that is
    # available and otherwise stays part of the model name. A bare name no
    # inference rule recognises runs under `default_provider`.
    class ModelSpec
      DEFAULT_PROVIDERS = %w[openai anthropic ollama openrouter].freeze

      DEFAULT_INFERENCE_RULES = [
        [ /\Aclaude/i, "anthropic" ],
        [ /\A(gpt-|o\d|chatgpt|text-embedding)/i, "openai" ],
        [ /:/, "ollama" ]
      ].freeze

      attr_reader :label, :provider, :model

      def self.parse(value, default_provider:, providers: DEFAULT_PROVIDERS, inference_rules: DEFAULT_INFERENCE_RULES)
        raw = value.to_s.strip
        raise ArgumentError, "model name is blank" if raw.blank?

        head, rest = raw.split("/", 2)
        if rest.present? && providers.include?(head)
          new(label: raw, provider: head, model: rest)
        elsif rest.present? && providers.include?("openrouter")
          new(label: raw, provider: "openrouter", model: raw)
        else
          new(label: raw, provider: infer_provider(raw, default_provider, inference_rules, providers), model: raw)
        end
      end

      # Parses a comma-separated string or an array, dropping blanks and
      # duplicates by label.
      def self.parse_all(values, **options)
        values = values.to_s.split(",") unless values.is_a?(Array)
        values.map { |value| coerce(value) }.reject(&:blank?).uniq.map { |value| parse(value, **options) }
      end

      # The label of one requested model. A caller that round-trips a spec —
      # the dashboard persists `specs.map(&:to_h)` and hands it back on a
      # re-run — sends a Hash, whose `to_s` is the inspected Hash and reaches
      # the provider as the model ID: `{"label" => "openrouter/gpt-4o-mini",
      # ...} is not a valid model ID`.
      #
      # @return [String, nil] nil when the value names no model
      def self.coerce(value)
        return value.to_h.stringify_keys.values_at("label", "model").compact.first.to_s.strip if value.respond_to?(:to_h) && !value.is_a?(String)

        value.to_s.strip
      end
      private_class_method :coerce

      # The provider a bare model name runs under. A rule whose provider the
      # caller does not offer is skipped, so an app without Ollama does not
      # route `name:tag` there.
      def self.infer_provider(model, default_provider, inference_rules, providers)
        rule = inference_rules.find { |pattern, provider| model.match?(pattern) && providers.include?(provider) }
        (rule ? rule.last : default_provider).to_s
      end

      def initialize(label:, provider:, model:)
        @label = label
        @provider = provider.to_s
        @model = model
      end

      def to_h
        { "label" => label, "provider" => provider, "model" => model }
      end

      def ==(other)
        other.is_a?(ModelSpec) && to_h == other.to_h
      end
      alias eql? ==

      def hash
        to_h.hash
      end
    end
  end
end
