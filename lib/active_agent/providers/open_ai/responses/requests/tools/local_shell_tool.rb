# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Tools
            # Local shell tool
            class LocalShellTool < Base
              attribute :type, :string, as: "local_shell"
              attribute :local_shell # Hash with optional configuration
            end
          end
        end
      end
    end
  end
end
