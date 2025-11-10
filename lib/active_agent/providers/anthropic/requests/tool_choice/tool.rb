# frozen_string_literal: true

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module ToolChoice
          # Tool choice - model will use the specified tool
          class Tool < Base
            attribute :type,                      :string, as: "tool"
            attribute :name,                      :string
            attribute :disable_parallel_tool_use, :boolean

            validates :name, presence: true
          end
        end
      end
    end
  end
end
