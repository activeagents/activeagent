# frozen_string_literal: true

require_relative "integration_case"

# AgentRun is the record an executor writes around a generation: the status
# a UI polls, the progress stream it renders, the fingerprint that groups
# runs into cohorts, and the tokens cost is estimated from.
class SolidAgentRunsTest < SolidAgentIntegrationTest
  requires_solid_agent "SolidAgent::RunFingerprint", "SolidAgent::ModelPricing"

  INSTRUCTIONS = "You are a support agent. Answer in two paragraphs at most."

  test "a run wraps a real generation and records what it cost" do
    run = AgentRun.create!(
      runnable: subject_record,
      agent_name: "Persistence::SupportAgent",
      action_name: "answer",
      input_prompt: "My invoice is wrong",
      trace_id: SecureRandom.uuid
    )

    run.record_instructions(INSTRUCTIONS)
    run.save!
    run.start!

    assert_predicate run, :running?
    assert_predicate run, :in_progress?

    run.append_event(kind: "llm", label: "answer", eid: "gen-1", status: "started")

    response = Persistence::SupportAgent.with(
      user: subject_record, message: run.input_prompt
    ).answer.generate_now

    run.append_event(kind: "llm", label: "answer", eid: "gen-1", status: "done", duration_ms: 12)

    run.complete!(
      output: response.message.content,
      input_tokens: response.usage&.input_tokens,
      output_tokens: response.usage&.output_tokens
    )

    assert_predicate run, :complete?
    assert_predicate run, :finished?
    assert_equal response.message.content, run.output
    assert_operator run.total_tokens, :>, 0
    assert run.duration_ms.present?

    assert_equal [ "started", "done" ], run.events.map { |event| event["status"] }
    assert_equal [ "gen-1", "gen-1" ], run.events.map { |event| event["eid"] }
  end

  test "a failed run keeps the error and stops being in progress" do
    run = AgentRun.create!(agent_name: "Persistence::SupportAgent", input_prompt: "boom")
    run.start!
    run.fail!(StandardError.new("provider timed out"))

    assert_predicate run, :failed?
    assert_predicate run, :finished?
    assert_equal "provider timed out", run.error_message
    refute run.cancel!, "a finished run cannot be cancelled"
  end

  test "runs group into cohorts by the instructions they executed under" do
    2.times do
      AgentRun.create!(agent_name: "Persistence::SupportAgent").tap do |run|
        run.record_instructions(INSTRUCTIONS)
        run.save!
      end
    end

    AgentRun.create!(agent_name: "Persistence::SupportAgent").tap do |run|
      run.record_instructions("#{INSTRUCTIONS} Be brief.")
      run.save!
    end

    cohorts = AgentRun.group(:instructions_digest).count

    assert_equal 2, cohorts.size, "expected one cohort per distinct instruction text"
    assert_equal [ 1, 2 ], cohorts.values.sort

    codenames = cohorts.keys.map { |digest| SolidAgent::RunFingerprint.codename(digest) }

    assert_equal codenames.uniq.size, codenames.size, "codenames must distinguish cohorts"
    codenames.each { |codename| assert_match(/\A[a-z]+-[a-z]+\z/, codename) }
  end

  test "the digest is stable across processes" do
    run = AgentRun.create!(agent_name: "Persistence::SupportAgent")
    run.record_instructions(INSTRUCTIONS)

    assert_equal SolidAgent::RunFingerprint.digest(INSTRUCTIONS), run.instructions_digest
    assert_equal SolidAgent::RunFingerprint.codename(run.instructions_digest), run.instructions_codename
  end

  test "generations price out through ModelPricing" do
    Persistence::SupportAgent.with(user: subject_record, message: "Price me").answer.generate_now

    generation = AgentGeneration.sole

    # The mock provider's model prices at zero by design, so the assertion
    # that matters is that estimation runs and stays consistent.
    assert_equal(
      SolidAgent::ModelPricing.estimate(
        model: generation.model,
        input_tokens: generation.input_tokens,
        output_tokens: generation.output_tokens
      ),
      generation.estimated_cost
    )

    assert_in_delta 0.048, SolidAgent::ModelPricing.estimate(
      model: "claude-sonnet-5", input_tokens: 12_000, output_tokens: 800
    ), 0.0005
  end

  test "one trace id joins the run, the conversation and the generation" do
    trace_id = SecureRandom.uuid
    run = AgentRun.create!(agent_name: "Persistence::SupportAgent", trace_id: trace_id)

    Persistence::SupportAgent.with(user: subject_record, message: "Correlate me").answer.generate_now
    AgentGeneration.update_all(trace_id: trace_id)
    AgentContext.update_all(trace_id: trace_id)

    assert_equal [ run ], AgentRun.with_trace(trace_id).to_a
    assert_equal 1, AgentContext.with_trace(trace_id).count
    assert_equal 1, AgentGeneration.with_trace(trace_id).count
  end
end
