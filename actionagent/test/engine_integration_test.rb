# frozen_string_literal: true

require "test_helper"
require_relative "telemetry_trace_test"

class DashboardEngineIntegrationTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::TelemetryTrace.delete_all
  end

  test "engine paths resolve to the dashboard directory" do
    engine = ActionAgent::Engine.instance
    root = ActionAgent::Engine.root

    assert_equal root.to_s, engine.root.to_s
    assert_includes engine.paths["app/models"].existent, root.join("app", "models").to_s
    assert_includes engine.paths["config/routes.rb"].existent, root.join("config", "routes.rb").to_s
  end

  test "every engine class eager loads" do
    # Autoloading only reaches what a test happens to touch; eager loading is
    # how a host app in production finds a file whose name and constant
    # disagree. Zeitwerk raises here rather than at 3am.
    assert_nothing_raised { ActionAgent::Engine.eager_load! }
  end

  test "dashboard classes are autoloadable without manual requires" do
    assert_equal "active_agent_telemetry_traces", ActionAgent::TelemetryTrace.table_name
    assert ActionAgent::ProcessTelemetryTracesJob < ActiveJob::Base
    assert ActionAgent::Api::TracesController < ActionController::API
  end

  test "every engine route maps to a shipped controller action" do
    ActionAgent::Engine.routes.routes.each do |route|
      controller = route.defaults[:controller]
      action = route.defaults[:action]
      next unless controller

      controller_class = "action_agent/#{controller.delete_prefix('action_agent/')}"
        .camelize.concat("Controller").constantize
      assert controller_class.action_methods.include?(action.to_s) || controller_class.instance_methods.include?(action.to_sym),
        "route #{route.path.spec} points at missing #{controller_class}##{action}"
    end
  end

  test "traces index renders" do
    ActionAgent::TelemetryTrace.create_from_payload(sample_payload)

    get "/activeagents/console/traces"

    assert_response :success
    assert_includes response.body, "SupportAgent"
  end

  test "traces index and metrics honor a trace_model_class override" do
    override = Class.new(ActionAgent::TelemetryTrace) do
      default_scope { where(service_name: "scoped-service") }
    end
    Object.const_set(:ScopedTelemetryTrace, override)

    ActionAgent::TelemetryTrace.create_from_payload(sample_payload)
    scoped = sample_payload
    scoped["service_name"] = "scoped-service"
    scoped["spans"][0]["name"] = "ScopedAgent.respond"
    scoped["spans"][0]["attributes"]["agent.class"] = "ScopedAgent"
    ActionAgent::TelemetryTrace.create_from_payload(scoped)

    ActionAgent.trace_model_class = "ScopedTelemetryTrace"

    get "/activeagents/console/traces"

    assert_response :success
    assert_includes response.body, "ScopedAgent"
    assert_not_includes response.body, "SupportAgent"

    get "/activeagents/console/traces/metrics"
    assert_response :success
    assert_includes response.body, "ScopedAgent"
  ensure
    ActionAgent.trace_model_class = nil
    Object.send(:remove_const, :ScopedTelemetryTrace)
  end

  test "engine root renders the dashboard" do
    get "/activeagents/"

    assert_response :success
    assert_includes response.body, "active-agent-dashboard"
  end

  test "the dashboard hands its initial state to the React app" do
    get "/activeagents/dashboard"

    assert_response :success
    props = JSON.parse(Nokogiri::HTML(response.body).at("#active-agent-dashboard")["data-props"])
    assert_equal "/activeagents", props["mountPath"]
    assert_equal [], props["initialAgents"]
    assert_includes props.dig("meta", "providers"), "openai"
  end

  test "client-side dashboard routes all render the same page" do
    get "/activeagents/agents/12/edit"

    assert_response :success
    assert_includes response.body, "active-agent-dashboard"
  end

  test "dashboard refuses unauthenticated access in production when no auth is configured" do
    Rails.env.stub(:production?, true) do
      get "/activeagents/console/traces"
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
      mount ActionAgent::Engine => "/observability", as: :renamed_dashboard
    end
    assert_equal "/observability/api/traces", aliased

    rooted = endpoint_path_for_routes(config) do
      mount ActionAgent::Engine => "/", as: :root_dashboard
    end
    assert_equal "/api/traces", rooted

    # The deployment the self-hosted guide recommends: engine at the root of
    # a dedicated subdomain. This is the shape the old helper-based lookup
    # silently got wrong.
    subdomain = endpoint_path_for_routes(config) do
      constraints subdomain: "activeagents" do
        mount ActionAgent::Engine => "/", as: :active_agent_subdomain
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
    trace = ActionAgent::TelemetryTrace.find_by(trace_id: payload["trace_id"])
    assert trace
    assert_equal "SupportAgent", trace.agent_class
    assert_equal 100, trace.total_input_tokens
  end

  test "local ingest requires the configured ingest_api_key" do
    ActionAgent.ingest_api_key = "secret-ingest-key"
    payload = sample_payload

    post "/activeagents/api/traces", params: { traces: [ payload ], sdk: {} }, as: :json
    assert_response :unauthorized

    post "/activeagents/api/traces", params: { traces: [ payload ], sdk: {} }, as: :json,
      headers: { "Authorization" => "Bearer wrong" }
    assert_response :unauthorized
    assert_nil ActionAgent::TelemetryTrace.find_by(trace_id: payload["trace_id"])

    post "/activeagents/api/traces", params: { traces: [ payload ], sdk: {} }, as: :json,
      headers: { "Authorization" => "Bearer secret-ingest-key" }
    assert_response :accepted
    assert ActionAgent::TelemetryTrace.find_by(trace_id: payload["trace_id"])
  ensure
    ActionAgent.ingest_api_key = nil
  end

  test "exactly one install generator resolves" do
    require "rails/generators"
    generator = Rails::Generators.find_by_namespace("action_agent:install")

    assert_equal ActionAgent::InstallGenerator, generator
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

    trace = ActionAgent::TelemetryTrace.find_by(trace_id: symbol_payload[:trace_id])
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
