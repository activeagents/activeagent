# frozen_string_literal: true

require "test_helper"

# Two runtimes, and the rule for choosing between them.
#
# A dashboard-authored agent is rows — a tool selection and instructions typed
# into the builder — and the engine builds a class for it at run time. An
# agent mirrored from host code already *is* a class, with its own tools,
# delegations and instructions that `tools` + `instructions` columns cannot
# express. Both have to keep working.
class HostAgentClassExecutionTest < ActiveSupport::TestCase
  class MirroredAgent < ApplicationAgent
    generate_with :mock, model: "mock-1"

    def ask
      prompt(message: "hi")
    end
  end

  setup do
    ActionAgent::Agent.delete_all
    @original = ActionAgent.run_host_agent_classes
  end

  teardown do
    ActionAgent.run_host_agent_classes = @original
    ActionAgent::Agent.delete_all
  end

  test "a dashboard-authored agent names no class, so the dynamic runtime keeps it" do
    ActionAgent.run_host_agent_classes = true
    agent = ActionAgent::Agent.create!(
      name: "Builder Made", provider: "mock", model: "mock-1", agent_class_name: nil
    )

    assert_nil service_for(agent).send(:resolved_host_class),
      "an agent with no class must fall to the dynamic runtime"
  end

  test "a mirrored agent resolves its host class when the flag is on" do
    ActionAgent.run_host_agent_classes = true
    agent = ActionAgent::Agent.create!(
      name: "Mirrored", provider: "mock", model: "mock-1",
      agent_class_name: "HostAgentClassExecutionTest::MirroredAgent"
    )

    assert_equal MirroredAgent, service_for(agent).send(:resolved_host_class)
  end

  test "the flag is off by default, so existing hosts are untouched" do
    refute @original, "run_host_agent_classes must default to off"

    ActionAgent.run_host_agent_classes = false
    agent = ActionAgent::Agent.create!(
      name: "Mirrored", provider: "mock", model: "mock-1",
      agent_class_name: "HostAgentClassExecutionTest::MirroredAgent"
    )

    assert_nil service_for(agent).send(:resolved_host_class)
  end

  test "a class name that no longer resolves falls back rather than failing" do
    ActionAgent.run_host_agent_classes = true
    agent = ActionAgent::Agent.create!(
      name: "Stale", provider: "mock", model: "mock-1", agent_class_name: "DeletedAgent"
    )

    # A renamed or removed class must not take the dashboard down with it.
    assert_nil service_for(agent).send(:resolved_host_class)
  end

  test "a class that is not an agent is not run as one" do
    ActionAgent.run_host_agent_classes = true
    agent = ActionAgent::Agent.create!(
      name: "Not An Agent", provider: "mock", model: "mock-1", agent_class_name: "String"
    )

    assert_nil service_for(agent).send(:resolved_host_class)
  end

  private

  def service_for(agent)
    ActionAgent::AgentExecutionService.allocate.tap do |service|
      service.instance_variable_set(:@agent_record, agent)
    end
  end
end
