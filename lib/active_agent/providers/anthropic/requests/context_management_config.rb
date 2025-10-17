# frozen_string_literal: true

require_relative "../../common/_base_model"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        # Context management configuration
        class ContextManagementConfig < Common::BaseModel
          attribute :edits, default: -> { [] } # Array of edit configurations

          validates :edits, presence: true
        end
      end
    end
  end
end
