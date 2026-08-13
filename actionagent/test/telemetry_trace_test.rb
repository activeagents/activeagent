# frozen_string_literal: true

require "test_helper"

class TelemetryTraceTest < ActiveSupport::TestCase
  def setup
    ActionAgent::TelemetryTrace.delete_all
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
        t.bigint :agent_id
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
    trace = ActionAgent::TelemetryTrace.create_from_payload(
      payload(spans: [ root_span(tokens: tokens), llm_span(tokens: tokens) ])
    )

    assert_equal 500, trace.total_input_tokens
    assert_equal 220, trace.total_output_tokens
    assert_equal 10, trace.total_thinking_tokens
  end

  test "counts root span tokens for single-span traces" do
    trace = ActionAgent::TelemetryTrace.create_from_payload(
      payload(spans: [ root_span(tokens: { "input" => 42, "output" => 7 }) ])
    )

    assert_equal 42, trace.total_input_tokens
    assert_equal 7, trace.total_output_tokens
  end

  test "counts root span tokens when child spans carry none" do
    trace = ActionAgent::TelemetryTrace.create_from_payload(
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
    trace = ActionAgent::TelemetryTrace.create_from_payload(error_payload)

    assert_equal "SupportAgent", trace.agent_class
    assert_equal "respond", trace.agent_action
    assert trace.error?
    assert_equal "Rate limit exceeded", trace.error_message
    assert_equal "mock", trace.provider
    assert_equal "mock-model", trace.model
  end

  def tool_span(attributes, id: "tool1", status: "OK")
    {
      "span_id" => id, "parent_span_id" => "llm1", "name" => "tool.#{attributes['tool.name']}",
      "type" => "tool", "duration_ms" => 42.0, "status" => status, "attributes" => attributes
    }
  end

  def prompt_span(roster)
    {
      "span_id" => "prompt1", "parent_span_id" => "root1", "name" => "prompt",
      "type" => "prompt", "duration_ms" => 2.0, "status" => "OK",
      "attributes" => { "prompt.input.tools" => roster.to_json }
    }
  end

  test "normalizes tool calls with the origin attributes instrumentation recorded" do
    trace = ActiveAgent::TelemetryTrace.create_from_payload(
      payload(spans: [
        root_span, llm_span(tokens: {}),
        tool_span({
          "tool.name" => "mcp__playwright__browser_click", "tool.origin" => "mcp",
          "tool.mcp_server" => "playwright", "tool.base_name" => "browser_click",
          "tool.input.args" => '{"ref":"e12"}'
        })
      ])
    )

    usage = trace.tool_usage.first
    assert_equal "mcp", usage[:origin]
    assert_equal "playwright", usage[:mcp_server]
    assert_equal "browser_click", usage[:base_name]
    assert_equal '{"ref":"e12"}', usage[:arguments]
    assert_equal 42.0, usage[:duration_ms]
  end

  test "classifies tool calls on read when the trace predates origin tagging" do
    trace = ActiveAgent::TelemetryTrace.create_from_payload(
      payload(spans: [ root_span, llm_span(tokens: {}), tool_span({ "tool.name" => "mcp__git__git_status" }) ])
    )

    usage = trace.tool_usage.first
    assert_equal "mcp", usage[:origin]
    assert_equal "git", usage[:mcp_server]
    assert_equal "git_status", usage[:base_name]
  end

  test "reads the tool roster the generation request offered" do
    trace = ActiveAgent::TelemetryTrace.create_from_payload(
      payload(spans: [
        root_span,
        prompt_span([ { "name" => "mcp__fetch__fetch", "description" => "Fetch a URL", "parameters" => [ "url" ] } ]),
        llm_span(tokens: {})
      ])
    )

    declared = trace.declared_tools.first
    assert_equal "mcp__fetch__fetch", declared[:name]
    assert_equal "Fetch a URL", declared[:description]
    assert_equal [ "url" ], declared[:parameters]
    assert_equal "fetch", declared[:mcp_server]
  end

  test "mcp_servers covers both offered and called servers" do
    trace = ActiveAgent::TelemetryTrace.create_from_payload(
      payload(spans: [
        root_span,
        prompt_span([ { "name" => "mcp__memory__read_graph" } ]),
        llm_span(tokens: {}),
        tool_span({ "tool.name" => "mcp__git__git_status" })
      ])
    )

    assert_equal %w[git memory], trace.mcp_servers
  end

  test "tool readers are empty for a trace with neither tool spans nor a roster" do
    trace = ActiveAgent::TelemetryTrace.create_from_payload(payload(spans: [ root_span, llm_span(tokens: {}) ]))

    assert_empty trace.tool_usage
    assert_empty trace.declared_tools
    assert_empty trace.mcp_servers
  end
end

TelemetryTraceTest.ensure_table!
