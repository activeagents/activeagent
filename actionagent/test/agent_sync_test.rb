# frozen_string_literal: true

require "test_helper"

# Mirroring host agent classes into Agent records — the step that lets the
# dashboard run, evaluate and release the agents an app already has in code.
class AgentSyncTest < ActiveSupport::TestCase
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

  test "a class that is not an agent is skipped, not raised" do
    result = ActionAgent::AgentSync.call([ String ], owner: nil_owner)

    assert result.success?, result.errors
    assert_empty result.agents
    assert_match "not an ActiveAgent::Base subclass", result.skipped.sole.skipped
  end

  private

  # Agent has no owner presence validation; the engine scopes by whatever the
  # host configures, and these tests exercise the sync itself.
  def nil_owner
    ActionAgent::Agent.new
  end
end
