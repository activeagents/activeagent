# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Tools
            # Custom tool
            class CustomTool < Base
              attribute :type, :string, as: "custom"
              attribute :name, :string # Required: name of the custom tool
              attribute :description, :string # Optional: description
              attribute :format # Optional: hash with input format
              # Can be { type: "text" } for unconstrained text
              # Or { type: "grammar", definition: string, syntax: "lark"|"regex" }

              validates :name, presence: true, length: { maximum: 64 }
              validates :name, format: { with: /\A[a-zA-Z0-9_-]+\z/, message: "must contain only a-z, A-Z, 0-9, underscores and dashes" }, if: -> { name.present? }
            end
          end
        end
      end
    end
  end
end
