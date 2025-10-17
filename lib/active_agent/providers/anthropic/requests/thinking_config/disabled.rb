# frozen_string_literal: true

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module ThinkingConfig
          # Disabled thinking configuration
          class Disabled < Base
            attribute :type, :string, as: "disabled"
          end
        end
      end
    end
  end
end
