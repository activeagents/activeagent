# frozen_string_literal: true

require "test_helper"
require_relative "telemetry_trace_test"

# redact_attributes: configured key patterns are scrubbed from span and
# span-event attributes before the payload leaves the process (transmission
# and local storage share build_trace_payload).
class TelemetryRedactionTest < ActiveSupport::TestCase
  TelemetryTraceTest.ensure_table!

  def setup
    ActiveAgent::TelemetryTrace.delete_all

    @configuration = ActiveAgent::Telemetry::Configuration.new
    @configuration.enabled = true
    @configuration.local_storage = true
    @configuration.service_name = "dummy"
  end

  test "redacts matching span and event attributes before storage" do
    tracer = ActiveAgent::Telemetry::Tracer.new(@configuration)

    tracer.trace("SupportAgent.respond") do |span|
      span.set_attribute("llm.api_key", "sk-live-123")
      span.set_attribute("http.authorization_token", "Bearer abc")
      span.set_attribute("llm.model", "claude-sonnet-5")
      span.add_event("tool.call", { "password" => "hunter2", "tool.name" => "fetch_url" })
    end
    tracer.flush

    trace = ActiveAgent::TelemetryTrace.first
    root = trace.spans.first

    assert_equal "[REDACTED]", root.dig("attributes", "llm.api_key")
    assert_equal "[REDACTED]", root.dig("attributes", "http.authorization_token")
    assert_equal "claude-sonnet-5", root.dig("attributes", "llm.model")

    event = root["events"].first
    assert_equal "[REDACTED]", event.dig("attributes", "password")
    assert_equal "fetch_url", event.dig("attributes", "tool.name")
  end

  test "custom redact_attributes replace the defaults" do
    @configuration.redact_attributes = %w[ssn]
    tracer = ActiveAgent::Telemetry::Tracer.new(@configuration)

    tracer.trace("SupportAgent.respond") do |span|
      span.set_attribute("user.ssn", "000-00-0000")
      span.set_attribute("llm.api_key", "left-alone-by-custom-config")
    end
    tracer.flush

    root = ActiveAgent::TelemetryTrace.first.spans.first
    assert_equal "[REDACTED]", root.dig("attributes", "user.ssn")
    assert_equal "left-alone-by-custom-config", root.dig("attributes", "llm.api_key")
  end

  test "empty redact_attributes disables scrubbing" do
    @configuration.redact_attributes = []
    tracer = ActiveAgent::Telemetry::Tracer.new(@configuration)

    tracer.trace("SupportAgent.respond") do |span|
      span.set_attribute("llm.api_key", "sk-live-123")
    end
    tracer.flush

    root = ActiveAgent::TelemetryTrace.first.spans.first
    assert_equal "sk-live-123", root.dig("attributes", "llm.api_key")
  end
end
