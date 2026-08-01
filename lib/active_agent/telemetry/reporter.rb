# frozen_string_literal: true

module ActiveAgent
  module Telemetry
    # The framework's reporter, now provided by the activeagents-telemetry
    # gem's BatchingReporter: buffered delivery on batch_size/flush_interval,
    # a blocking flush, and a shutdown that waits out in-flight sends so
    # traces reported near process exit are delivered rather than dropped.
    #
    # Local storage is handled by Configuration#local_store, which routes
    # traces through the dashboard's trace model instead of HTTP.
    #
    # @see ActiveAgents::Telemetry::BatchingReporter
    class Reporter < ActiveAgents::Telemetry::BatchingReporter
      def initialize(configuration)
        # sample: false — the Tracer applies head-based sampling at trace
        # creation, before any span is built; sampling again here would
        # compound the rate to rate².
        super(configuration, sdk_name: "activeagent", sdk_version: ActiveAgent::VERSION, sample: false)
      end
    end
  end
end
