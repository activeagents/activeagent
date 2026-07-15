# frozen_string_literal: true

require "test_helper"
require_relative "telemetry_trace_test"

# Trace-id correlation and flush determinism: the pieces that let an app's
# own records (e.g. solid_agent generations reading
# prompt_options[:trace_id]) point at the telemetry trace that produced
# them, and that make Telemetry.flush reliable in short-lived processes.
class TelemetryCorrelationTest < ActiveSupport::TestCase
  TelemetryTraceTest.ensure_table!

  def setup
    ActiveAgent::TelemetryTrace.delete_all

    @configuration = ActiveAgent::Telemetry::Configuration.new
    @configuration.enabled = true
    @configuration.local_storage = true
    @configuration.service_name = "dummy"
  end

  test "tracer honors a caller-supplied trace_id" do
    tracer = ActiveAgent::Telemetry::Tracer.new(@configuration)

    supplied = SecureRandom.uuid
    tracer.trace("SupportAgent.respond", trace_id: supplied) do |span|
      span.set_tokens(input: 10, output: 5)
    end
    tracer.flush

    trace = ActiveAgent::TelemetryTrace.find_by(trace_id: supplied)
    assert trace.present?, "trace should be stored under the supplied trace_id"
  end

  test "tracer generates a trace_id when none is supplied" do
    tracer = ActiveAgent::Telemetry::Tracer.new(@configuration)

    tracer.trace("SupportAgent.respond") { |span| span.set_tokens(input: 1, output: 1) }
    tracer.flush

    assert_equal 1, ActiveAgent::TelemetryTrace.count
    assert ActiveAgent::TelemetryTrace.first.trace_id.present?
  end

  test "flush waits for the send to complete" do
    reporter = ActiveAgent::Telemetry::Reporter.new(@configuration)

    reporter.report(stored_payload)
    reporter.flush

    # No sleep: flush must not return before the trace is persisted.
    assert_equal 1, ActiveAgent::TelemetryTrace.count
  ensure
    reporter&.shutdown
  end

  test "shutdown flushes buffered traces" do
    reporter = ActiveAgent::Telemetry::Reporter.new(@configuration)

    reporter.report(stored_payload)
    reporter.shutdown

    assert_equal 1, ActiveAgent::TelemetryTrace.count
  end

  test "instrumented generations share the trace_id exposed in prompt_options" do
    original_tracer = swap_global_tracer(ActiveAgent::Telemetry::Tracer.new(@configuration))

    agent_class = Class.new(ApplicationAgent) do
      def self.name = "CorrelationProbeAgent"

      def ping
        prompt(message: "hello", instructions: "Reply briefly.")
      end
    end
    agent_class.include(ActiveAgent::Telemetry::Instrumentation)
    agent_class.instrument_telemetry!

    agent = agent_class.with({}).ping
    agent.generate_now rescue nil # provider errors don't matter; the trace does

    ActiveAgent::Telemetry.flush

    trace = ActiveAgent::TelemetryTrace.order(:created_at).last
    assert trace.present?, "instrumented generation should store a trace"
    # Instrumentation mints the id via SecureRandom.uuid into
    # prompt_options[:trace_id] (dashed UUID); the tracer's own fallback is
    # 32-char hex. A dashed UUID here proves the id flowed from
    # prompt_options — i.e. external records reading prompt_options can
    # correlate with this trace.
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, trace.trace_id,
      "trace_id should be the prompt_options UUID, not a tracer-generated hex id")
  ensure
    swap_global_tracer(original_tracer)
  end

  private

  def stored_payload
    {
      "trace_id" => SecureRandom.hex(16),
      "service_name" => "dummy",
      "environment" => "test",
      "timestamp" => Time.current.iso8601(6),
      "spans" => [
        {
          "span_id" => "root1", "parent_span_id" => nil, "name" => "SupportAgent.respond",
          "type" => "root", "duration_ms" => 10.0, "status" => "OK",
          "attributes" => { "agent.class" => "SupportAgent", "agent.action" => "respond" },
          "tokens" => { "input" => 5, "output" => 2 }
        }
      ]
    }
  end

  def swap_global_tracer(tracer)
    previous = ActiveAgent::Telemetry.instance_variable_get(:@tracer)
    ActiveAgent::Telemetry.instance_variable_set(:@tracer, tracer)
    previous_enabled = ActiveAgent::Telemetry.configuration.enabled
    ActiveAgent::Telemetry.configuration.enabled = true
    ActiveAgent::Telemetry.configuration.local_storage = true
    @restore_enabled = previous_enabled
    previous
  end
end
