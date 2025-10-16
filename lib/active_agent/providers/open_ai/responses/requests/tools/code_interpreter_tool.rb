# frozen_string_literal: true

require_relative "base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Tools
            # Built-in code interpreter tool
            class CodeInterpreterTool < Base
              attribute :type, :string, as: "code_interpreter"
              attribute :container # Required: can be string (container ID) or hash { type: "auto", file_ids: [] }

              validates :container, presence: true
            end
          end
        end
      end
    end
  end
end
