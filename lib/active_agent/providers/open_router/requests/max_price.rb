# frozen_string_literal: true

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        # Maximum price configuration for provider routing
        # Specifies USD price per million tokens for different operations
        # See: https://openrouter.ai/docs/provider-routing
        class MaxPrice < Common::BaseModel
        attribute :prompt,     :float # Price per million prompt tokens (input)
        attribute :completion, :float # Price per million completion tokens (output)
        attribute :image,      :float # Price per image
        attribute :audio,      :float # Price per audio unit
        attribute :request,    :float # Price per request

        validates :prompt,     numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
        validates :completion, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
        validates :image,      numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
        validates :audio,      numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
        validates :request,    numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

        # Backwards Compatibility
        alias_attribute :prompt_tokens, :prompt
        alias_attribute :completion_tokens, :completion
        end
      end
    end
  end
end
