# frozen_string_literal: true

require "test_helper"

# Mirroring host agent classes into Agent records — the step that lets the
# dashboard run, evaluate and release the agents an app already has in code.
class AgentSyncTest < ActiveSupport::TestCase
  class AssembledAgent < ApplicationAgent
    generate_with :mock, model: "mock-1"

    def self.dashboard_instructions_text = "assembled for the dashboard"

    def ask
      prompt(message: "hi")
    end
  end

  class InvoiceAgent < ApplicationAgent
    generate_with :mock, model: "mock-1"

    def ask
      prompt(message: "hi")
    end
  end

  setup do
    ActionAgent::Agent.delete_all
  end

  teardown do
    ActionAgent::Agent.delete_all
  end

  test "creates a record carrying the class name, so releases can resolve it" do
    result = ActionAgent::AgentSync.call([ InvoiceAgent ], owner: nil_owner)

    assert result.success?, result.errors
    agent = result.agents.sole
    assert_equal "AgentSyncTest::InvoiceAgent", agent.agent_class_name
    assert_equal "agent-sync-test-invoice-agent", agent.slug
    assert_equal "mock", agent.provider
    assert_equal "mock-1", agent.model
  end

  test "re-running updates in place rather than duplicating" do
    ActionAgent::AgentSync.call([ InvoiceAgent ], owner: nil_owner)

    assert_difference -> { ActionAgent::Agent.count }, 0 do
      ActionAgent::AgentSync.call([ InvoiceAgent ], owner: nil_owner)
    end
  end

  test "the operator's provider and model survive a re-sync" do
    agent = ActionAgent::AgentSync.call([ InvoiceAgent ], owner: nil_owner).agents.sole
    agent.update!(model: "operator-choice")

    ActionAgent::AgentSync.call([ InvoiceAgent ], owner: nil_owner)

    # The code owns what an agent is; the operator owns how it runs. A model
    # picked in the dashboard must survive the next deploy's sync.
    assert_equal "operator-choice", agent.reload.model
  end

  test "an agent that assembles its own instructions is asked for them" do
    result = ActionAgent::AgentSync.call([ AssembledAgent ], owner: nil_owner)

    # A record agent's prompt comes from a template it shares with siblings,
    # filled from assigns it computes — the class is the only thing that knows
    # how to build it, so the sync asks rather than rendering a template that
    # would come back empty.
    assert_equal "assembled for the dashboard", result.agents.sole.instructions
  end

  test "a class that is not an agent is skipped, not raised" do
    result = ActionAgent::AgentSync.call([ String ], owner: nil_owner)

    assert result.success?, result.errors
    assert_empty result.agents
    assert_match "not an ActiveAgent::Base subclass", result.skipped.sole.skipped
  end

  test "each owner syncs into its own record when agents are owned per user" do
    previous = ActionAgent.user_class
    ActionAgent.user_class = "User"
    alice = User.create!(name: "Alice", email: "alice-#{SecureRandom.hex(4)}@example.com", age: 30)
    bob = User.create!(name: "Bob", email: "bob-#{SecureRandom.hex(4)}@example.com", age: 30)

    alices = ActionAgent::AgentSync.call([ InvoiceAgent ], owner: alice).agents.sole
    bobs = ActionAgent::AgentSync.call([ InvoiceAgent ], owner: bob).agents.sole

    assert_not_equal alices.id, bobs.id, "a second owner's sync must not take over the first owner's agent"
    assert_equal alice.id, alices.reload.user_id
    assert_equal bob.id, bobs.user_id
  ensure
    ActionAgent.user_class = previous
    ActionAgent::Agent.delete_all
    alice&.destroy
    bob&.destroy
  end

  private

  # Agent has no owner presence validation; the engine scopes by whatever the
  # host configures, and these tests exercise the sync itself.
  def nil_owner
    ActionAgent::Agent.new
  end
end
