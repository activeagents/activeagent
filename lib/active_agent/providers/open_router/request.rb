# frozen_string_literal: true

require_relative "../open_ai/options"
require_relative "requests/response_format"
require_relative "requests/prediction"
require_relative "requests/provider_preferences"
require_relative "requests/types"

module ActiveAgent
  module Providers
    module OpenRouter
      class Request < OpenAI::Chat::Request
        # Prompting Options
        attribute :model,           :string,  default: "openrouter/auto"
        attribute :response_format, Requests::Types::ResponseFormatType.new
        attribute :max_tokens,      :integer
        attribute :stop # Can be string or array

        # LLM Parameters
        attribute :seed,               :integer
        attribute :top_p,              :float
        attribute :top_k,              :integer
        attribute :frequency_penalty,  :float
        attribute :presence_penalty,   :float
        attribute :repetition_penalty, :float
        attribute :top_logprobs,       :integer
        attribute :min_p,              :float
        attribute :top_a,              :float
        attribute :logit_bias # Hash of token_id => bias value

        # Tool calling (inherited from OpenAI but explicitly documented)
        # attribute :tools, :json
        # attribute :tool_choice, :json

        # Predicted outputs
        attribute :prediction, Requests::Types::PredictionType.new

        # OpenRouter-specific parameters
        attribute :transforms,                                        default: -> { [] } # Array of strings
        attribute :models,                                            default: -> { [] } # Array of model strings for fallback
        attribute :route,    :string,                                 default: "fallback"
        attribute :provider, Requests::Types::ProviderPreferencesType.new, default: {}
        attribute :user,     :string # Stable identifier for end-users

        # Validations for parameters with specific ranges
        validates :max_tokens,         numericality: { greater_than_or_equal_to: 1 },                            allow_nil: true
        validates :top_p,              numericality: { greater_than: 0, less_than_or_equal_to: 1 },              allow_nil: true
        validates :top_k,              numericality: { greater_than_or_equal_to: 1 },                            allow_nil: true
        validates :frequency_penalty,  numericality: { greater_than_or_equal_to: -2, less_than_or_equal_to: 2 }, allow_nil: true
        validates :presence_penalty,   numericality: { greater_than_or_equal_to: -2, less_than_or_equal_to: 2 }, allow_nil: true
        validates :repetition_penalty, numericality: { greater_than: 0, less_than_or_equal_to: 2 },              allow_nil: true
        validates :min_p,              numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },  allow_nil: true
        validates :top_a,              numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },  allow_nil: true
        validates :route,              inclusion:    { in: [ "fallback" ] },                                     allow_nil: true

        # Backwards Compatibility
        delegate_attributes :data_collection, :enable_fallbacks, :sort, :ignore, :only, :quantizations, :max_price, to: :provider
        alias_attribute :fallback_models, :models
      end
    end
  end
end
