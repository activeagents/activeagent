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
    # the {#process} method.
    #
    # @return [Proc] callback proc that accepts (action_name, *args, **kwargs)
    def tools_function
      proc do |action_name, *args, **kwargs|
        process(action_name, *args, **kwargs)
      end
    end
  end
end
