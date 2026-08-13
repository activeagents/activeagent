# frozen_string_literal: true

# Transitional aliases for the names this engine shipped under when it lived
# inside the activeagent gem (<= 1.1.0).
#
# Three of these matter for more than tidiness:
#
#   * ActiveAgent::ProcessTelemetryTracesJob — Active Job serializes the class
#     name into the queue payload, so a job enqueued before the upgrade is
#     dequeued after it and must still resolve to something.
#   * ActiveAgent::TelemetryTrace — apps subclass it (the activeagents.ai
#     platform does) and it is referenced from initializers.
#   * ActiveAgent::Dashboard — every existing initializer calls
#     ActiveAgent::Dashboard.configure.
#
# Each warns once through the deprecator and forwards to the new constant.
# Remove in the next major.
module ActionAgent
  module Compatibility
    RENAMED = {
      "Dashboard" => "ActionAgent",
      "TelemetryTrace" => "ActionAgent::TelemetryTrace",
      "ProcessTelemetryTracesJob" => "ActionAgent::ProcessTelemetryTracesJob"
    }.freeze

    # Installs const_missing on ActiveAgent so the old names keep resolving
    # without eagerly loading the engine's models (which would drag Active
    # Record in at boot, the very thing the gem split fixed).
    def self.install!
      return if @installed

      ActiveAgent.singleton_class.prepend(ConstMissing)
      @installed = true
    end

    module ConstMissing
      def const_missing(name)
        replacement = RENAMED[name.to_s]
        return super unless replacement

        ActionAgent.deprecator.warn(
          "ActiveAgent::#{name} has moved to #{replacement}. " \
          "The dashboard is now the actionagent gem; update your references."
        )
        replacement.constantize
      end
    end
  end
end
