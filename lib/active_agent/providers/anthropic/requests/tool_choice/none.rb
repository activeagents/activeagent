# frozen_string_literal: true

module ActiveAgent
  module Providers
    module Anthropic
      module Requests
        module ToolChoice
          # None tool choice - model will not use tools
          class None < Base
            attribute :type, :string, as: "none"
          end
        end
      end
    end
  end
end
