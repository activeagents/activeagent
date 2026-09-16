# frozen_string_literal: true

require "test_helper"

# A release cut from the agent's code, and the version every trace, run and
# evaluation run is pinned to as a result.
class AgentReleaseTest < ActiveSupport::TestCase
  class BillingAgent < ApplicationAgent
    generate_with :mock

    def ask
      prompt(message: "hi")
    end
  end

  setup do
    ActionAgent::TelemetryTrace.delete_all
    ActionAgent::Agent.delete_all
    BillingAgent.reset_release!
    @agent = ActionAgent::Agent.create!(
      name: "Billing", provider: "mock", model: "mock-1", agent_class_name: "AgentReleaseTest::BillingAgent"
    )
  end

  test "a release cuts one version per digest, carrying the digest and the deploy" do
    first = @agent.record_release!(digest: "aaaaaaaaaaaa", manifest: { "model" => "m1" }, revision: "sha-1")

    assert first.release?
    assert_equal "aaaaaaaaaaaa", first.release_digest
    assert_equal "sha-1", first.revision
    assert_equal "aaaaaaaaaaaa", @agent.reload.release_digest
    assert_match(/first release/, first.change_summary)
    assert_equal({ "model" => "m1" }, first.configuration_snapshot["release"])

    # A redeploy of the same agent is not a new version.
    count = @agent.agent_versions.count
    assert_equal first.id, @agent.record_release!(digest: "aaaaaaaaaaaa", manifest: { "model" => "m1" }, revision: "sha-2").id
    assert_equal count, @agent.agent_versions.count

    second = @agent.record_release!(digest: "bbbbbbbbbbbb", manifest: { "model" => "m2" }, revision: "sha-3")

    assert_equal first.version_number + 1, second.version_number
    assert_match(/model/, second.change_summary)
    assert_equal second, @agent.latest_release
  end

  test "AgentRelease cuts from the host class and skips a record whose class is not releasable" do
    ghost = ActionAgent::Agent.create!(name: "Ghost", provider: "mock", model: "m", agent_class_name: "Nope::Missing")

    result = ActionAgent::AgentRelease.call(revision: "deploy-1")
    row = result.rows.find { |r| r.agent == @agent }

    assert row.cut
    assert_equal BillingAgent.release_digest, row.version.release_digest
    assert_equal "deploy-1", row.version.revision
    assert result.rows.find { |r| r.agent == ghost }.skipped

    assert_not ActionAgent::AgentRelease.call(revision: "deploy-2").rows.find { |r| r.agent == @agent }.cut
  end

  test "an ingested trace is pinned to the release its root span names" do
    version = @agent.record_release!(digest: "cccccccccccc")

    trace = ActionAgent::TelemetryTrace.create_from_payload(payload("agent.version" => "cccccccccccc"), {}, agent: @agent)

    assert_equal version.id, trace.reload.agent_version_id
    assert_equal version, trace.agent_version
  end

  test "a trace without a digest takes the agent's latest version, and an unknown digest none" do
    version = @agent.record_release!(digest: "dddddddddddd")

    assert_equal version.id, ActionAgent::TelemetryTrace.create_from_payload(payload, {}, agent: @agent).reload.agent_version_id
    assert_nil ActionAgent::TelemetryTrace.create_from_payload(payload("agent.version" => "eeeeeeeeeeee"), {}, agent: @agent).reload.agent_version_id
  end

  test "runs and evaluation runs record the version they executed under" do
    version = @agent.record_release!(digest: "ffffffffffff")

    run = @agent.agent_runs.create!(input_prompt: "hi", action_name: "ask", trace_id: SecureRandom.uuid)
    assert_equal version.id, run.agent_version_id

    evaluation = ActionAgent::Evaluation.create!(
      agent: @agent, name: "suite", criteria: [ { "key" => "present", "type" => "response_present" } ]
    )
    assert_equal version.id, evaluation.evaluation_runs.create!(status: :pending).agent_version_id
  end

  test "a generation from the mirrored class is attributed to the mirror, not to an observed twin" do
    config = ActiveAgent::Telemetry.configuration
    saved = { enabled: config.enabled, local_storage: config.local_storage }
    config.enabled = true
    config.local_storage = true
    ActiveAgent::Base.include(ActiveAgent::Telemetry::Instrumentation)
    ActiveAgent::Base.instrument_telemetry!

    BillingAgent.ask.generate_now
    ActiveAgent::Telemetry.tracer.flush

    assert_equal @agent.id, ActionAgent::TelemetryTrace.order(:id).last.agent_id
    assert_equal 1, ActionAgent::Agent.count, "the trace registered an observed twin instead of matching the mirror"
  ensure
    config.enabled = saved[:enabled]
    config.local_storage = saved[:local_storage]
  end

  test "a real generation stamps the release on its trace" do
    config = ActiveAgent::Telemetry.configuration
    saved = { enabled: config.enabled, local_storage: config.local_storage }
    config.enabled = true
    config.local_storage = true
    # The dummy boots with telemetry off, so the railtie never installed the
    # generation instrumentation; install it here (idempotent).
    ActiveAgent::Base.include(ActiveAgent::Telemetry::Instrumentation)
    ActiveAgent::Base.instrument_telemetry!
    ActiveAgent::Release.revision = "rev-9"
    version = @agent.record_release!(digest: BillingAgent.release_digest, revision: "rev-9")

    BillingAgent.ask.generate_now
    ActiveAgent::Telemetry.tracer.flush
    trace = ActionAgent::TelemetryTrace.order(:id).last

    assert trace, "no trace stored"
    assert_equal BillingAgent.release_digest, trace.root_span.dig("attributes", "agent.version")
    assert_equal "rev-9", trace.root_span.dig("attributes", "agent.revision")
    assert_equal "rev-9", trace.root_span.dig("attributes", "service.version")
    assert_equal version.id, trace.agent_version_id
  ensure
    ActiveAgent::Release.revision = nil
    config.enabled = saved[:enabled]
    config.local_storage = saved[:local_storage]
  end

  private

  def payload(attributes = {})
    {
      "trace_id" => SecureRandom.uuid, "service_name" => "dummy", "environment" => "test",
      "timestamp" => Time.current.iso8601(6),
      "spans" => [ {
        "span_id" => "r1", "parent_span_id" => nil, "name" => "BillingAgent.ask", "type" => "root",
        "duration_ms" => 10.0, "status" => "OK",
        "attributes" => { "agent.class" => "AgentReleaseTest::BillingAgent", "agent.action" => "ask" }.merge(attributes)
      } ]
    }
  end
end
