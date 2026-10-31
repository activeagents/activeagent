# frozen_string_literal: true

module ActiveAgent
  # Provides tool/function calling support for agent classes.
  #
  # Enables agent classes to respond to tool calls from providers
  # by routing them to the appropriate action methods.
  module Tooling
    extend ActiveSupport::Concern

    # Returns a proc that handles tool/function calls from providers.
    #
    # The proc routes tool calls to the appropriate action method using
    # the {#process} method. Secret answers the generation received (see
    # InputRequests) are scrubbed from the result and from any error, before
    # either reaches the provider or telemetry.
    #
    # @return [Proc] callback proc that accepts (action_name, *args, **kwargs)
    def tools_function
      proc do |action_name, *args, **kwargs|
        # Marked as a tool call so a refusal is reported to the model as a
        # result rather than raised through the run (see Authorization).
        result = with_tool_call { process(action_name, *args, **kwargs) }
        scrub_input_request_secrets(result)
      rescue StandardError => error
        raise_without_input_request_secrets(error)
      end
    end

    # A callback the provider runs the calls it serves from an MCP server
    # around, which never reach {#tools_function}. It receives the tool name,
    # its arguments and a block that makes the call, and returns the block's
    # result. Nil unless a host that records a generation's tool calls (see
    # Evals::Capture) sets it on the instance.
    #
    # @return [Proc, nil]
    def tool_observer = nil
  end
end
