require "test_helper"

# The tools are plain Ruby: every one of them can be called, and tested,
# without a model.
class IssueToolsTest < ActiveSupport::TestCase
  setup do
    @alex = User.create!(name: "Alex Kim", handle: "alex", team: "support")
    @sofia = User.create!(name: "Sofia Alvarez", handle: "sofia", team: "auth")
    @crash = Issue.create!(title: "Checkout returns 500 for gift cards", priority: "urgent", component: "checkout", reporter: @alex)
    @report = Issue.create!(title: "Gift card orders crash", component: "checkout", reporter: @alex)
    @passkey = Issue.create!(title: "Passkey sign-in loops", priority: "high", component: "auth", reporter: @alex)
  end

  test "the editor is offered reads and writes as separate rosters" do
    assert_equal %w[find_issues count_issues get_issue search_issues], IssueTools.tool_names
    assert_equal %w[create_issue update_issue add_comment], IssueActionTools.tool_names.last(3)
    assert_equal IssueTools.tool_names + UserTools.tool_names + IssueActionTools.tool_names, ActionAgent.schema_tool_names
  end

  test "search finds an existing report by any of its words, most urgent first" do
    found = IssueTools.call("search_issues", query: "gift card checkout")

    assert_equal [ @crash.id, @report.id ], found[:results].pluck(:id)
  end

  test "search leaves closed issues out unless asked" do
    @report.update!(status: "closed")

    assert_equal [ @crash.id ], IssueTools.call("search_issues", query: "gift")[:results].pluck(:id)
    assert_equal 2, IssueTools.call("search_issues", query: "gift", include_closed: true)[:count]
  end

  test "a filter on an undeclared column is refused rather than ignored" do
    assert_match(/title/, IssueTools.call("find_issues", title: "Passkey sign-in loops")[:error])
  end

  test "an update is made in the name of the person the agent acts for, and leaves a trail" do
    owner = UserTools.call("find_users", team: "auth")[:results].sole
    result = IssueActionTools.call("update_issue", actor: @alex, id: @passkey.id, assignee_id: owner[:id], reason: "Owns auth.")

    assert_equal @sofia.id, result[:assignee_id]
    comment = @passkey.comments.sole
    assert comment.via_agent
    assert_equal @alex, comment.author
    assert_equal "Assigned to Sofia Alvarez.\n\nOwns auth.", comment.body
  end

  test "marking a duplicate closes the report and links it" do
    IssueActionTools.call("update_issue", actor: @alex, id: @report.id, duplicate_of_id: @crash.id, status: "closed")

    assert_equal [ @crash, "closed" ], [ @report.reload.duplicate_of, @report.status ]
    assert_not_nil @report.closed_at
  end

  test "mistakes come back as errors the model can act on" do
    assert_match(/No issue found/, IssueActionTools.call("update_issue", id: 0, status: "closed")[:error])
    assert_match(/Nothing to change/, IssueActionTools.call("update_issue", id: @crash.id)[:error])
    assert_match(/not included/, IssueActionTools.call("update_issue", id: @crash.id, priority: "severe")[:error])
    assert_match(/existing user/, IssueActionTools.call("update_issue", id: @crash.id, assignee_id: 9999)[:error])
    assert_match(/Title can't be blank/, IssueActionTools.call("create_issue", actor: @alex, title: "")[:error])
  end

  test "an agent named after the model starts with the read tools only" do
    assert_equal IssueTools.tool_names, ActionAgent::Agent.new(name: "Issue Agent").conventional_schema_tools
  end
end
