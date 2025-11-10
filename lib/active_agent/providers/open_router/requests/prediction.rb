# frozen_string_literal: true

module ActiveAgent
  module Providers
    module OpenRouter
      module Requests
        class Prediction < Common::BaseModel
          attribute :type, :string
          attribute :content, :string

          validates :type, inclusion: { in: %w[content] }, allow_nil: true
          validates :content, presence: true, if: -> { type.present? }
        end
      end
    end
  end
end
