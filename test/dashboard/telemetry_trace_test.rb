# frozen_string_literal: true

require "test_helper"

class TelemetryTraceTest < ActiveSupport::TestCase
  def setup
    ActiveAgent::TelemetryTrace.delete_all
  end

  # Must run OUTSIDE test transactions (transactional tests roll DDL back
  # in SQLite), so callers invoke it at file-load time.
  def self.ensure_table!
    connection = ActiveRecord::Base.connection
    unless connection.table_exists?(:active_agent_telemetry_traces)
      connection.create_table :active_agent_telemetry_traces do |t|
        t.string :trace_id, null: false
        t.string :service_name
        t.string :environment
        t.datetime :timestamp, null: false
        t.json :spans, default: []
        t.json :resource_attributes, default: {}
        t.json :sdk_info, default: {}
        t.integer :total_duration_ms
        t.integer :total_input_tokens, default: 0
        t.integer :total_output_tokens, default: 0
        t.integer :total_thinking_tokens, default: 0
        t.string :status, default: "UNSET"
        t.string :agent_class
        t.string :agent_action
        t.text :error_message
        t.timestamps
      end
    end
  end

  def payload(spans:)
    {
      "trace_id" => SecureRandom.hex(16),
      "service_name" => "dummy",
      "environment" => "test",
      "timestamp" => Time.current.iso8601(6),
      "resource_attributes" => {},
      "spans" => spans
    }
  end

  def root_span(tokens: {}, status: "OK", attributes: {})
    {
      "span_id" => "root1", "parent_span_id" => nil, "name" => "SupportAgent.respond",
      "type" => "root", "duration_ms" => 1200.0, "status" => status,
      "attributes" => { "agent.class" => "SupportAgent", "agent.action" => "respond" }.merge(attributes),
      "tokens" => tokens
    }
  end

  def llm_span(tokens:, status: "OK")
    {
      "span_id" => "llm1", "parent_span_id" => "root1", "name" => "llm.generate",
      "type" => "llm", "duration_ms" => 1100.0, "status" => status,
      "attributes" => { "llm.provider" => "mock", "llm.model" => "mock-model" },
      "tokens" => tokens
    }
  end

  test "does not double-count tokens mirrored onto the root span" do
    tokens = { "input" => 500, "output" => 220, "thinking" => 10 }
    trace = ActiveAgent::TelemetryTrace.create_from_payload(
      payload(spans: [ root_span(tokens: tokens), llm_span(tokens: tokens) ])
    )

    assert_equal 500, trace.total_input_tokens
    assert_equal 220, trace.total_output_tokens
    assert_equal 10, trace.total_thinking_tokens
  end

  test "counts root span tokens for single-span traces" do
    trace = ActiveAgent::TelemetryTrace.create_from_payload(
      payload(spans: [ root_span(tokens: { "input" => 42, "output" => 7 }) ])
    )

    assert_equal 42, trace.total_input_tokens
    assert_equal 7, trace.total_output_tokens
  end

  test "counts root span tokens when child spans carry none" do
    trace = ActiveAgent::TelemetryTrace.create_from_payload(
      payload(spans: [ root_span(tokens: { "input" => 30, "output" => 12 }), llm_span(tokens: {}) ])
    )

    assert_equal 30, trace.total_input_tokens
    assert_equal 12, trace.total_output_tokens
  end

  test "extracts agent info, status and error message" do
    error_payload = payload(
      spans: [
        root_span(status: "ERROR", attributes: { "error.message" => "Rate limit exceeded" }),
        llm_span(tokens: { "input" => 5 }, status: "ERROR")
      ]
    )
    trace = ActiveAgent::TelemetryTrace.create_from_payload(error_payload)

    assert_equal "SupportAgent", trace.agent_class
    assert_equal "respond", trace.agent_action
    assert trace.error?
    assert_equal "Rate limit exceeded", trace.error_message
    assert_equal "mock", trace.provider
    assert_equal "mock-model", trace.model
  end
end

TelemetryTraceTest.ensure_table!
