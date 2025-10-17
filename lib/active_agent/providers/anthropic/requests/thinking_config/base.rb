# frozen_string_literal: true

require_relative "../../../common/_base_model"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module ThinkingConfig
          # Base class for thinking configuration
          class Base < Common::BaseModel
            attribute :type, :string

            validates :type, presence: true, inclusion: { in: %w[enabled disabled] }
          end
        end
      end
    end
  end
end
