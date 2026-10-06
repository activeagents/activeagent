# frozen_string_literal: true

require "test_helper"
require_relative "support/exploration_setup"

# The tools an agent can call in a run, which a scenario run's diagnosis and
# an exploration's verdicts both read.
class RuntimeToolRosterTest < ActiveSupport::TestCase
  include ExplorationSetup

  def setup
    reset_exploration_records!
    @project = create_explored_project!
    @agent = @project.target_agent
    @agent.update!(tools: [ "search" ])
  end

  test "lists what the agent's servers serve beside its toolbox tools" do
    stub_runtime

    roster = ActionAgent::RuntimeToolRoster.new(@agent)

    assert_equal %w[find_orders lookup_order web_search], roster.tools.keys.sort
    assert_equal "lookup_order tool", roster.tools["lookup_order"]
    assert_empty roster.discovery_errors
    assert_not roster.all_servers_failed?
  end

  test "a server of the agent's own that fails discovery is named, and contributes nothing" do
    stub_runtime(fail: true)

    roster = ActionAgent::RuntimeToolRoster.new(@agent)

    assert_equal [ "web_search" ], roster.tools.keys
    assert_equal [ @project.current_sandbox_session.runtime_server_key ], roster.discovery_errors.keys
    assert roster.all_servers_failed?
  end

  test "an extra sandbox that fails discovery raises" do
    stub_runtime(fail: true)
    key = @project.current_sandbox_session.runtime_server_key

    assert_raises(ActionAgent::MCPToolDispatcher::SandboxUnavailable) do
      ActionAgent::RuntimeToolRoster.new(@agent, extra_server_keys: [ key ]).tools
    end
  end
end
