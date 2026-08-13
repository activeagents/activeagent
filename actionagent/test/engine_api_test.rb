# frozen_string_literal: true

require "test_helper"
require_relative "telemetry_trace_test"

# The dashboard's JSON API, exercised through the engine mounted in the dummy
# app at /activeagents. The dummy app configures no user or account model, so
# these cover the single-user self-hosted shape; the ownership seam itself is
# covered separately below.
class DashboardEngineApiTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::Agent.delete_all
    ActionAgent::TelemetryTrace.delete_all
  end

  def teardown
    ActionAgent.quota_checker = nil
    ActionAgent.usage_recorder = nil
    ActionAgent.execution_enabled = true
  end

  def create_agent(name: "Support", **attributes)
    ActionAgent::Agent.create!(
      { name: name, provider: "openai", model: "gpt-4o-mini" }.merge(attributes)
    )
  end

  test "agents are listed with their scorecards" do
    agent = create_agent(name: "Support")

    get "/activeagents/api/agents"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [ agent.id ], body["agents"].map { |a| a["id"] }
    assert body["agents"].first.key?("stats")
    assert_includes body.dig("meta", "providers"), "anthropic"
  end

  test "creating an agent versions it" do
    post "/activeagents/api/agents", params: {
      agent: { name: "Researcher", provider: "openai", model: "gpt-4o-mini", instructions: "Be brief." }
    }

    assert_response :created
    agent = ActionAgent::Agent.find(JSON.parse(response.body).dig("agent", "id"))
    assert_equal "researcher", agent.slug
    assert_equal 1, agent.agent_versions.count
  end

  test "agent search is case-insensitive on every adapter" do
    create_agent(name: "Support Triage")
    create_agent(name: "Billing")

    get "/activeagents/api/agents", params: { q: "SUPPORT" }

    assert_response :success
    assert_equal [ "Support Triage" ], JSON.parse(response.body)["agents"].map { |a| a["name"] }
  end

  test "the host app's quota checker can refuse an execution" do
    agent = create_agent
    ActionAgent.quota_checker = ->(_owner, kind) { "Out of runs" if kind == :execution }

    post "/activeagents/api/agents/#{agent.id}/execute", params: { prompt: "hi" }

    assert_response :payment_required
    assert_equal "Out of runs", JSON.parse(response.body)["message"]
  end

  test "execution can be turned off entirely" do
    agent = create_agent
    ActionAgent.execution_enabled = false

    post "/activeagents/api/agents/#{agent.id}/execute", params: { prompt: "hi" }

    assert_response :forbidden
  end

  test "a run reports usage back to the host app" do
    agent = create_agent
    recorded = []
    ActionAgent.usage_recorder = ->(owner, kind) { recorded << [ owner, kind ] }

    post "/activeagents/api/agents/#{agent.id}/execute", params: { prompt: "hi" }

    assert_response :accepted
    assert_equal [ [ nil, :execution ] ], recorded
  end

  test "metrics and traces read the same store the ingest endpoint writes" do
    ActionAgent::TelemetryTrace.create_from_payload(sample_trace_payload)

    get "/activeagents/api/traces"
    assert_response :success
    assert_equal 1, JSON.parse(response.body)["traces"].size

    get "/activeagents/api/metrics"
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body.dig("summary", "total_requests")
    assert_equal 15, body.dig("summary", "tokens_used")
    # Hourly buckets are grouped in SQL, which each adapter spells its own way.
    assert_equal 24, body["hourly_requests"].size
    assert_equal 1, body["hourly_requests"].sum { |hour| hour["count"] }
  end

  test "evaluations are scoped to an agent" do
    agent = create_agent

    post "/activeagents/api/evaluations", params: {
      evaluation: { agent_id: agent.id, name: "Answers", judge_kind: "rules" },
      criteria: [ { key: "present", type: "response_present" } ]
    }

    assert_response :created
    assert_equal 1, agent.evaluations.count
  end

  test "an unknown record answers 404 as JSON rather than raising" do
    get "/activeagents/api/agents/999999"

    assert_response :not_found
    assert_equal "Record not found", JSON.parse(response.body)["error"]
  end

  private

  def sample_trace_payload
    {
      "trace_id" => SecureRandom.hex(16),
      "service_name" => "dummy",
      "environment" => "test",
      "timestamp" => Time.current.iso8601(6),
      "resource_attributes" => {},
      "spans" => [
        {
          "span_id" => "r1", "parent_span_id" => nil, "name" => "SupportAgent.respond",
          "type" => "root", "duration_ms" => 12.0, "status" => "OK",
          "attributes" => { "agent.class" => "SupportAgent", "agent.action" => "respond" },
          "tokens" => { "input" => 10, "output" => 5, "thinking" => 0 }
        }
      ]
    }
  end
end

# The ownership seam: which column scopes a model is a per-model declaration
# resolved from configuration, so one set of controllers serves a single-user
# install, a per-user install and a multi-tenant platform.
class DashboardOwnershipTest < ActiveSupport::TestCase
  def teardown
    ActionAgent.user_class = nil
    ActionAgent.account_class = nil
  end

  test "nothing is owned when the host app configures no owner model" do
    assert_nil ActionAgent::Agent.owner_association
    assert_equal ActionAgent::Agent.all.to_sql,
      ActionAgent::Agent.for_owner(nil).to_sql
  end

  # The dangerous direction. "No owner resolved" and "this install has no
  # owners" look the same at the call site and mean opposite things: the
  # first must show nothing, the second everything.
  test "an unresolved owner sees nothing once an owner model is configured" do
    ActionAgent::Agent.create!(name: "Owned", provider: "openai", model: "gpt-4o-mini")
    ActionAgent.user_class = "User"

    assert_equal :user, ActionAgent::Agent.owner_association
    assert_empty ActionAgent::Agent.for_owner(nil),
      "a nil owner must not fall through to every owner's agents"
    assert_equal 1, ActionAgent::Agent.count
  ensure
    ActionAgent::Agent.delete_all
  end

  test "agents prefer a user and keys prefer an account" do
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "User" # the dummy app has no Account

    agent_candidates = ActionAgent::Agent.owner_candidates
    key_candidates = ActionAgent::ApiKey.owner_candidates

    assert_equal [ :user, :account ], agent_candidates
    assert_equal [ :account, :user ], key_candidates
  end

  test "the table prefix is configurable so a host app keeps its own names" do
    assert_equal "active_agent_agents", ActionAgent::Agent.table_name

    ActionAgent.table_name_prefix = ""
    ActionAgent::Agent.reset_table_name

    assert_equal "agents", ActionAgent::Agent.table_name
  ensure
    ActionAgent.table_name_prefix = "active_agent_"
    ActionAgent::Agent.reset_table_name
  end
end
