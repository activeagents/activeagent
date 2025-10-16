# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Tools
            # Function tool for custom function calling
            class FunctionTool < Base
              attribute :type, :string, as: "function"
              attribute :name, :string
              attribute :parameters # Hash - JSON Schema object (required)
              attribute :strict, :boolean # Required - whether to enforce strict parameter validation (default true)
              attribute :description, :string # Optional description

              validates :name, presence: true, length: { maximum: 64 }
              validates :name, format: { with: /\A[a-zA-Z0-9_-]+\z/, message: "must contain only a-z, A-Z, 0-9, underscores and dashes" }, if: -> { name.present? }
              validates :parameters, presence: true
              validates :strict, inclusion: { in: [ true, false ] }, allow_nil: false
            end
          end
        end
      end
    end
  end
end
