# frozen_string_literal: true

require "active_agent/providers/common/model"
require_relative "sources/_types"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module Content
          # Base class for all content items
          class Base < Common::BaseModel
            attribute :type, :string

            validates :type, presence: true
          end
        end
      end
    end
  end
end
