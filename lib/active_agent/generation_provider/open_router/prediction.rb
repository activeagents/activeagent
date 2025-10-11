# frozen_string_literal: true

module ActiveAgent
  module GenerationProvider
    module OpenRouter
      class Prediction < Common::Options

        attribute :type, :string
        attribute :content, :string

        validates :type, inclusion: { in: %w[content] }, allow_nil: true
        validates :content, presence: true, if: -> { type.present? }
      end
    end
  end
end
