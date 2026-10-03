# frozen_string_literal: true

require "test_helper"
require_relative "support/exploration_setup"

# explorations_submit on the MCP facade: an agent outside the dashboard
# submits the candidate scenarios it found, under the API key's owner, and
# gets back each candidate's verdict and the link to review them.
class McpExplorationsTest < ActionDispatch::IntegrationTest
  include ExplorationSetup

  def setup
    reset_exploration_records!
    @project = create_explored_project!
    @key = ActionAgent::ApiKey.create!(name: "Harness")
    stub_runtime
  end

  def teardown
    ActionAgent.mcp_dashboard_tools = nil
    ActionAgent.permission_checker = nil
    ActionAgent.multi_tenant = false
    ActionAgent.account_class = nil
  end

  def submit(arguments, key: @key)
    post "/activeagents/mcp",
      params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "explorations_submit", arguments: arguments } }.to_json,
      headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{key.token}" }
    JSON.parse(response.body)
  end

  def tool_names
    post "/activeagents/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
      headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{@key.token}" }
    JSON.parse(response.body).dig("result", "tools").map { |tool| tool["name"] }
  end

  test "it is listed while the dashboard tools are on" do
    assert_includes tool_names, "explorations_submit"

    ActionAgent.mcp_dashboard_tools = false
    assert_not_includes tool_names, "explorations_submit"
  end

  test "it stores an external exploration and returns each verdict and the review link, needing only the key" do
    ActionAgent.permission_checker = ->(_user, _action, _subject) { false }

    body = submit({ project_id: @project.id, candidates: [
      candidate("Where is order A-17?", tools: [ "lookup_order" ], rubric: "Gives the status."),
      candidate("Refund A-17 with #{SECRET}", tools: [ "refund_order" ], provenance: { steps: [ "Opened Orders" ] })
    ] })

    result = body.dig("result", "structuredContent")
    assert_nil body.dig("result", "isError"), body.inspect
    exploration = ActionAgent::Exploration.find(result.dig("exploration", "id"))
    assert_equal [ "external", "review", @project.id ], [ exploration.source, exploration.status, exploration.project_id ]
    assert_equal [ { "id" => 1, "prompt" => "Where is order A-17?", "verdict" => "answerable", "missing_tools" => [], "state" => "proposed" },
                   { "id" => 2, "prompt" => "Refund A-17 with [REDACTED]", "verdict" => "needs_tool",
                     "missing_tools" => [ "refund_order" ], "state" => "proposed" } ], result["candidates"]
    assert_equal "http://www.example.com/activeagents/explorations/#{exploration.id}", result["review_url"]
    assert_equal [ "Opened Orders" ], exploration.candidates.second.dig("provenance", "steps")
  end

  test "exploration_id adds to an earlier submission, numbering on from it" do
    first = submit({ project_id: @project.id, candidates: [ candidate("Where is order A-17?") ] }).dig("result", "structuredContent")
    id = first.dig("exploration", "id")

    second = submit({ exploration_id: id, candidates: [ candidate("Which orders shipped late?") ] }).dig("result", "structuredContent")

    assert_equal [ 2 ], second["candidates"].map { |row| row["id"] }
    assert_equal 2, ActionAgent::Exploration.find(id).candidates.size
    assert_equal 1, ActionAgent::Exploration.count
  end

  test "another owner's project or exploration is not found, and a call naming no target is invalid" do
    ActionAgent.multi_tenant = true
    ActionAgent.account_class = "ExplorationTestAccount"
    mine = ExplorationTestAccount.create!(name: "mine")
    theirs = ExplorationTestAccount.create!(name: "theirs")
    @project.update_columns(account_id: theirs.id)
    other = ActionAgent::Exploration.build_for(project: @project.reload, source: "external", status: "review")
    other.save_with_candidates!([ candidate("Where is order A-17?") ])
    key = ActionAgent::ApiKey.create!(name: "Mine", account_id: mine.id)

    body = submit({ project_id: @project.id, candidates: [ candidate("Hello") ] }, key: key)
    assert_equal true, body.dig("result", "isError")
    assert_match(/No project #{@project.id} was found/, body.dig("result", "content", 0, "text"))

    body = submit({ exploration_id: other.id, candidates: [ candidate("Hello") ] }, key: key)
    assert_equal true, body.dig("result", "isError")
    assert_equal 1, other.reload.candidates.size

    body = submit({ candidates: [ candidate("Hello") ] }, key: key)
    assert_equal(-32602, body.dig("error", "code"))

    body = submit({ project_id: @project.id, candidates: "Hello" }, key: key)
    assert_match(/candidates must be an array/, body.dig("result", "content", 0, "text"))
  end

  test "a refused batch is a tool error and stores nothing" do
    body = submit({ project_id: @project.id, candidates: [ candidate("Hello"), { prompt: "" } ] })

    assert_equal true, body.dig("result", "isError")
    assert_match(/Candidate 2 has no prompt/, body.dig("result", "content", 0, "text"))
    assert_equal 0, ActionAgent::Exploration.count
  end
end
