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

    get "/activeagents/traces"

    assert_response :success
    assert_includes response.body, "SupportAgent"
  end

  test "traces index and metrics honor a trace_model_class override" do
    override = Class.new(ActiveAgent::TelemetryTrace) do
      default_scope { where(service_name: "scoped-service") }
    end
    Object.const_set(:ScopedTelemetryTrace, override)

    ActiveAgent::TelemetryTrace.create_from_payload(sample_payload)
    scoped = sample_payload
    scoped["service_name"] = "scoped-service"
    scoped["spans"][0]["name"] = "ScopedAgent.respond"
    scoped["spans"][0]["attributes"]["agent.class"] = "ScopedAgent"
    ActiveAgent::TelemetryTrace.create_from_payload(scoped)

    ActiveAgent::Dashboard.trace_model_class = "ScopedTelemetryTrace"

    get "/activeagents/traces"

    assert_response :success
    assert_includes response.body, "ScopedAgent"
    assert_not_includes response.body, "SupportAgent"

    get "/activeagents/traces/metrics"
    assert_response :success
    assert_includes response.body, "ScopedAgent"
  ensure
    ActiveAgent::Dashboard.trace_model_class = nil
    Object.send(:remove_const, :ScopedTelemetryTrace)
  end

  test "engine root renders the traces index" do
    get "/activeagents/"

    assert_response :success
  end

  test "dashboard overview redirects to traces in ERB mode" do
    get "/activeagents/dashboard"

    assert_response :redirect
    assert_includes response.location, "/activeagents/traces"
  end

  test "dashboard refuses unauthenticated access in production when no auth is configured" do
    Rails.env.stub(:production?, true) do
      get "/activeagents/traces"
    end

    assert_response :forbidden
    assert_includes response.body, "authentication_method"
  end

  test "local endpoint path derives from the engine's actual mount" do
    config = ActiveAgent::Telemetry::Configuration.new
    config.local_storage = true

    assert_equal "/activeagents/api/traces", config.local_endpoint_path
    assert_equal "/activeagents/api/traces", config.resolved_endpoint
  end

  # The mount is found in the route set, not via the default `active_agent_path`
  # helper — so an `as:` override (the docs' subdomain example) still resolves.
  test "local endpoint path resolves for aliased and root mounts" do
    config = ActiveAgent::Telemetry::Configuration.new

    aliased = endpoint_path_for_routes(config) do
      mount ActiveAgent::Dashboard::Engine => "/observability", as: :renamed_dashboard
    end
    assert_equal "/observability/api/traces", aliased

    rooted = endpoint_path_for_routes(config) do
      mount ActiveAgent::Dashboard::Engine => "/", as: :root_dashboard
    end
    assert_equal "/api/traces", rooted

    # The deployment the self-hosted guide recommends: engine at the root of
    # a dedicated subdomain. This is the shape the old helper-based lookup
    # silently got wrong.
    subdomain = endpoint_path_for_routes(config) do
      constraints subdomain: "activeagents" do
        mount ActiveAgent::Dashboard::Engine => "/", as: :active_agent_subdomain
      end
    end
    assert_equal "/api/traces", subdomain
  end

  test "local endpoint path falls back when the engine is not mounted" do
    config = ActiveAgent::Telemetry::Configuration.new

    unmounted = endpoint_path_for_routes(config) { get "up", to: proc { [ 200, {}, [ "ok" ] ] } }

    assert_equal ActiveAgent::Telemetry::Configuration::LOCAL_ENDPOINT_PATH, unmounted
  end

  test "local ingest endpoint persists traces" do
    payload = sample_payload
    post "/activeagents/api/traces", params: { traces: [ payload ], sdk: { name: "activeagent" } }, as: :json

    assert_response :accepted
    trace = ActiveAgent::TelemetryTrace.find_by(trace_id: payload["trace_id"])
    assert trace
    assert_equal "SupportAgent", trace.agent_class
    assert_equal 100, trace.total_input_tokens
  end

  test "local ingest requires the configured ingest_api_key" do
    ActiveAgent::Dashboard.ingest_api_key = "secret-ingest-key"
    payload = sample_payload

    post "/activeagents/api/traces", params: { traces: [ payload ], sdk: {} }, as: :json
    assert_response :unauthorized

    post "/activeagents/api/traces", params: { traces: [ payload ], sdk: {} }, as: :json,
      headers: { "Authorization" => "Bearer wrong" }
    assert_response :unauthorized
    assert_nil ActiveAgent::TelemetryTrace.find_by(trace_id: payload["trace_id"])

    post "/activeagents/api/traces", params: { traces: [ payload ], sdk: {} }, as: :json,
      headers: { "Authorization" => "Bearer secret-ingest-key" }
    assert_response :accepted
    assert ActiveAgent::TelemetryTrace.find_by(trace_id: payload["trace_id"])
  ensure
    ActiveAgent::Dashboard.ingest_api_key = nil
  end

  test "exactly one install generator resolves" do
    require "rails/generators"
    generator = Rails::Generators.find_by_namespace("active_agent:dashboard:install")

    assert_equal ActiveAgent::Dashboard::InstallGenerator, generator
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

    reporter.report(symbol_payload)
    reporter.flush

    trace = ActiveAgent::TelemetryTrace.find_by(trace_id: symbol_payload[:trace_id])
    assert trace, "symbol-keyed payload was not persisted"
    assert_equal 9, trace.total_input_tokens
  ensure
    reporter&.shutdown
  end

  private

  # Resolves the ingest path against a temporary route set, restoring the
  # real routes (and the dummy app's /activeagents mount) afterward.
  def endpoint_path_for_routes(config, &route_definition)
    route_set = ActionDispatch::Routing::RouteSet.new
    route_set.draw(&route_definition)

    mount = config.mount_path_in(route_set)
    mount ? "#{mount}/api/traces" : ActiveAgent::Telemetry::Configuration::LOCAL_ENDPOINT_PATH
  end

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
