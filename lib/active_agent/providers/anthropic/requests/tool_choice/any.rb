# frozen_string_literal: true

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module ToolChoice
          # Any tool choice - model will use any available tools
          class Any < Base
            attribute :type,                      :string,  as: "any"
            attribute :disable_parallel_tool_use, :boolean
          end
        end
      end
    end
  end
end
