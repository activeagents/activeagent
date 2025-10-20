# frozen_string_literal: true

require "active_agent/providers/common/model"

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        # Container parameters for code execution and skills
        class ContainerParams < Common::BaseModel
          attribute :id,     :string
          attribute :skills, default: -> { [] } # Array of skill specifications

          validates :skills, length: { maximum: 8 }, allow_nil: true
        end
      end
    end
  end
end
