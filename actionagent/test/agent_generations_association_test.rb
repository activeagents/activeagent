# frozen_string_literal: true

require "test_helper"

# Generations hang off AgentContext polymorphically, so reading an agent's
# recorded history meant writing that join by hand — the engine's own
# EvaluationRunnerService did, in a private method a host cannot reuse. The
# association makes it one definition and keeps the shape behind the engine
# boundary.
class ActionAgentAgentGenerationsAssociationTest < ActiveSupport::TestCase
  def setup
    @agent = ActionAgent::Agent.create!(name: "Support", provider: "mock", model: "mock")
    @other = ActionAgent::Agent.create!(name: "Other", provider: "mock", model: "mock")
  end

  def generation_for(agent, model:, content: "hi")
    context = ActionAgent::AgentContext.create!(contextable: agent, agent_name: "SupportAgent", action_name: "respond")
    ActionAgent::AgentGeneration.create!(agent_context: context, model: model, content: content)
  end

  test "an agent reads the generations recorded against it" do
    mine = generation_for(@agent, model: "gpt-5.5")
    theirs = generation_for(@other, model: "gpt-5.5")

    assert_equal [ mine.id ], @agent.generations.pluck(:id)
    assert_equal [ theirs.id ], @other.generations.pluck(:id)
  end

  test "generations is a scope, so it counts and filters without loading" do
    generation_for(@agent, model: "gpt-5.5")
    generation_for(@agent, model: "claude-opus-5")

    assert_equal 2, @agent.generations.count
    assert_equal 1, @agent.generations.where(model: "gpt-5.5").count
    # The dashboard's "has this agent actually run?" question.
    assert_equal 0, @other.generations.count
  end

  # The association exists to read generations. Destroying an agent has never
  # taken its contexts with it, and this must not quietly start doing so.
  test "destroying an agent leaves its contexts alone, as before" do
    generation_for(@agent, model: "gpt-5.5")
    context_count = ActionAgent::AgentContext.count

    @agent.destroy!

    assert_equal context_count, ActionAgent::AgentContext.count
  end
end
