# frozen_string_literal: true

require "test_helper"
require_relative "telemetry_trace_test"

class DashboardEngineIntegrationTest < ActionDispatch::IntegrationTest
  def setup
    ActiveAgent::TelemetryTrace.delete_all
  end

  test "engine paths resolve to the dashboard directory" do
    engine = ActiveAgent::Dashboard::Engine.instance
    root = ActiveAgent::Dashboard::Engine.root

    assert_equal root.to_s, engine.root.to_s
    assert_includes engine.paths["app/models"].existent, root.join("app", "models").to_s
    assert_includes engine.paths["config/routes.rb"].existent, root.join("config", "routes.rb").to_s
  end

  test "dashboard classes are autoloadable without manual requires" do
    assert_equal "active_agent_telemetry_traces", ActiveAgent::TelemetryTrace.table_name
    assert ActiveAgent::ProcessTelemetryTracesJob < ActiveJob::Base
    assert ActiveAgent::Dashboard::Api::TracesController < ActionController::API
  end

  test "every engine route maps to a shipped controller action" do
    ActiveAgent::Dashboard::Engine.routes.routes.each do |route|
      controller = route.defaults[:controller]
      action = route.defaults[:action]
      next unless controller

      controller_class = "active_agent/#{controller.delete_prefix('active_agent/')}"
        .camelize.concat("Controller").constantize
      assert controller_class.action_methods.include?(action.to_s) || controller_class.instance_methods.include?(action.to_sym),
        "route #{route.path.spec} points at missing #{controller_class}##{action}"
    end
  end

  test "traces index renders" do
    ActiveAgent::TelemetryTrace.create_from_payload(sample_payload)

    get "/active_agent/traces"

    assert_response :success
    assert_includes response.body, "SupportAgent"
  end

  test "engine root renders the traces index" do
    get "/active_agent/"

    assert_response :success
  end

  test "dashboard overview redirects to traces in ERB mode" do
    get "/active_agent/dashboard"

    assert_response :redirect
    assert_includes response.location, "/active_agent/traces"
  end

  test "local ingest endpoint matches LOCAL_ENDPOINT_PATH and persists traces" do
    endpoint = ActiveAgent::Telemetry::Configuration::LOCAL_ENDPOINT_PATH
    assert_equal "/active_agent/api/traces", endpoint

    payload = sample_payload
    post endpoint, params: { traces: [ payload ], sdk: { name: "activeagent" } }, as: :json

    assert_response :accepted
    trace = ActiveAgent::TelemetryTrace.find_by(trace_id: payload["trace_id"])
    assert trace
    assert_equal "SupportAgent", trace.agent_class
    assert_equal 100, trace.total_input_tokens
  end

  test "reporter local storage persists symbol-keyed tracer payloads" do
    config = ActiveAgent::Telemetry::Configuration.new
    config.enabled = true
    config.local_storage = true
    reporter = ActiveAgent::Telemetry::Reporter.new(config)

    symbol_payload = {
      trace_id: SecureRandom.hex(16),
      service_name: "dummy",
      environment: "test",
      timestamp: Time.current.iso8601(6),
      resource_attributes: {},
      spans: [
        { span_id: "r1", parent_span_id: nil, name: "SupportAgent.respond", type: "root",
          duration_ms: 10.0, status: "OK",
          attributes: { "agent.class" => "SupportAgent", "agent.action" => "respond" },
          tokens: { input: 9, output: 4, thinking: 0 } }
      ]
    }

    reporter.send(:store_traces_locally, [ symbol_payload ])

    trace = ActiveAgent::TelemetryTrace.find_by(trace_id: symbol_payload[:trace_id])
    assert trace, "symbol-keyed payload was not persisted"
    assert_equal 9, trace.total_input_tokens
  ensure
    reporter&.shutdown
  end

  private

  def sample_payload
    {
      "trace_id" => SecureRandom.hex(16),
      "service_name" => "dummy",
      "environment" => "test",
      "timestamp" => Time.current.iso8601(6),
      "resource_attributes" => {},
      "spans" => [
        { "span_id" => "r1", "parent_span_id" => nil, "name" => "SupportAgent.respond",
          "type" => "root", "start_time" => 1.second.ago.iso8601(6),
          "end_time" => Time.current.iso8601(6), "duration_ms" => 1000.0, "status" => "OK",
          "attributes" => { "agent.class" => "SupportAgent", "agent.action" => "respond" },
          "tokens" => { "input" => 100, "output" => 40, "thinking" => 0 } }
      ]
    }
  end
end
