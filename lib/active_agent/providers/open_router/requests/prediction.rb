# frozen_string_literal: true

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        # Prediction configuration for prefilling responses
        #
        # Allows prefilling the start of the model's response. When provided,
        # the model continues from this predicted content.
        #
        # @example Content prediction
        #   prediction = Prediction.new(
        #     type: 'content',
        #     content: 'Once upon a time'
        #   )
        #
        # @see https://platform.openai.com/docs/api-reference/chat/create#chat-create-prediction
        class Prediction < Common::BaseModel
          # @!attribute type
          #   @return [String] prediction type (currently only 'content' is supported)
          attribute :type, :string

          # @!attribute content
          #   @return [String] predicted content to prefill the response
          attribute :content, :string

          validates :type, inclusion: { in: %w[content] }, allow_nil: true
          validates :content, presence: true, if: -> { type.present? }
        end
      end
    end
  end
end
