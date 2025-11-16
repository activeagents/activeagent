# frozen_string_literal: true

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        # Maximum price configuration for provider routing
        #
        # Specifies maximum acceptable prices (in USD per million tokens or per
        # operation) for filtering providers. OpenRouter will only route to
        # providers within these price constraints.
        #
        # @example Setting prompt and completion limits
        #   max_price = MaxPrice.new(
        #     prompt: 0.01,      # $0.01 per million input tokens
        #     completion: 0.03   # $0.03 per million output tokens
        #   )
        #
        # @example Setting all constraints
        #   max_price = MaxPrice.new(
        #     prompt: 0.01,
        #     completion: 0.03,
        #     image: 0.001,
        #     audio: 0.002,
        #     request: 0.0001
        #   )
        #
        # @see https://openrouter.ai/docs/provider-routing OpenRouter Provider Routing
        # @see ProviderPreferences
        class MaxPrice < Common::BaseModel
          # @!attribute prompt
          #   @return [Float, nil] maximum price per million prompt tokens (input)
          attribute :prompt,     :float

          # @!attribute completion
          #   @return [Float, nil] maximum price per million completion tokens (output)
          attribute :completion, :float

          # @!attribute image
          #   @return [Float, nil] maximum price per image operation
          attribute :image,      :float

          # @!attribute audio
          #   @return [Float, nil] maximum price per audio operation
          attribute :audio,      :float

          # @!attribute request
          #   @return [Float, nil] maximum price per request
          attribute :request,    :float

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
