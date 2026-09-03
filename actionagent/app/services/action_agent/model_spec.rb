# frozen_string_literal: true

module ActionAgent
  # A candidate model for a comparison run, resolved from the string a user
  # types in the compare-models field.
  #
  # `label` is that string verbatim and keys the model's cohort in the run's
  # scores. `provider` and `model` are what the run executes under:
  #
  #   "anthropic/claude-sonnet-5"       → anthropic, claude-sonnet-5
  #   "claude-haiku-4-5"                → anthropic (inferred), claude-haiku-4-5
  #   "gpt-5-mini"                      → openai (inferred), gpt-5-mini
  #   "qwen3:8b"                        → ollama (inferred from the tag), qwen3:8b
  #   "meta-llama/llama-3.3-70b"        → openrouter, meta-llama/llama-3.3-70b
  #   "openrouter/anthropic/claude-3"   → openrouter, anthropic/claude-3
  #
  # A name no rule recognises runs under `default_provider`, the evaluated
  # agent's own provider.
  ModelSpec = Struct.new(:label, :provider, :model, keyword_init: true) do
    # Providers a leading path segment may name. `mock` is the framework's
    # test double, accepted so the test suite can compare cohorts offline.
    PROVIDERS = (Agent::PROVIDERS + %w[mock]).freeze

    INFERENCE_RULES = [
      [ /\Aclaude/i, "anthropic" ],
      [ /\A(gpt-|o\d|chatgpt|text-embedding)/i, "openai" ],
      [ /:/, "ollama" ]
    ].freeze

    def self.parse(value, default_provider:)
      raw = value.to_s.strip
      raise ArgumentError, "model name is blank" if raw.blank?

      head, rest = raw.split("/", 2)
      if rest.present? && PROVIDERS.include?(head)
        new(label: raw, provider: head, model: rest)
      elsif rest.present?
        new(label: raw, provider: "openrouter", model: raw)
      else
        new(label: raw, provider: infer_provider(raw, default_provider), model: raw)
      end
    end

    # Parses each entry, dropping blanks and duplicates by label.
    def self.parse_all(values, default_provider:)
      Array(values).map(&:to_s).map(&:strip).reject(&:blank?).uniq.map do |value|
        parse(value, default_provider: default_provider)
      end
    end

    def self.infer_provider(model, default_provider)
      rule = INFERENCE_RULES.find { |pattern, _| model.match?(pattern) }
      (rule ? rule.last : default_provider).to_s
    end

    def to_h
      { "label" => label, "provider" => provider, "model" => model }
    end
  end
end
