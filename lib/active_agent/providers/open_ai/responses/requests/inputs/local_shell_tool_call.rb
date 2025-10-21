# frozen_string_literal: true

require_relative "tool_call_base"

module ActiveAgent
  module Providers
    module OpenAI
      module Responses
        module Requests
          module Inputs
            # Local shell tool call - runs command on local shell
            class LocalShellToolCall < ToolCallBase
              attribute :type, :string, as: "local_shell_call"
              attribute :call_id, :string
              attribute :action # LocalShellExecAction object

              validates :type, inclusion: { in: %w[local_shell_call], allow_nil: false }
              validates :call_id, presence: true
              validates :action, presence: true
            end
          end
        end
      end
    end
  end
end
