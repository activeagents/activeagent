# frozen_string_literal: true

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module ThinkingConfig
          # Enabled thinking configuration with budget
          class Enabled < Base
            attribute :type,          :string,  as: "enabled"
            attribute :budget_tokens, :integer

            validates :budget_tokens, presence: true
            validates :budget_tokens, numericality: { greater_than_or_equal_to: 1024 }, allow_nil: false
          end
        end
      end
    end
  end
end
