# frozen_string_literal: true

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module ToolChoice
          # Auto tool choice - model decides whether to use tools
          class Auto < Base
            attribute :type,                      :string,  as: "auto"
            attribute :disable_parallel_tool_use, :boolean
          end
        end
      end
    end
  end
end
