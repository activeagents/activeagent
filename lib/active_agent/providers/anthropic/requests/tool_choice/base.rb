# frozen_string_literal: true

require_relative "../../../common/_base_model"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module ToolChoice
          # Base class for tool choice configurations
          class Base < Common::BaseModel
            attribute :type, :string

            validates :type, presence: true, inclusion: { in: %w[auto any tool none] }
          end
        end
      end
    end
  end
end
