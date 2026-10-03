# frozen_string_literal: true

require "test_helper"

# An API key created in the dashboard records the user who created it, so a
# call made with an account's key acts as that user rather than as the
# account.
class ApiKeyCreatorTest < ActionDispatch::IntegrationTest
  def setup
    ActionAgent::ApiKey.delete_all
    ActionAgent::Agent.delete_all
    ActionAgent::AgentRun.delete_all
  end

  def teardown
    ActionAgent.multi_tenant = false
    ActionAgent.user_class = nil
    ActionAgent.account_class = nil
    ActionAgent.current_user_resolver = nil
    ActionAgent.current_account_resolver = nil
  end

  test "a key created in a multi-tenant dashboard belongs to the account and records its creator" do
    me, account = sign_in_to_account

    post "/activeagents/api/api_keys", params: { name: "mine" }

    assert_response :created
    key = ActionAgent::ApiKey.find_by!(name: "mine")
    assert_equal account.id, key.account_id
    assert_equal me.id, key.user_id
    assert_equal me, key.creator
  end

  test "an MCP call with that key runs as its creator" do
    me, account = sign_in_to_account
    post "/activeagents/api/api_keys", params: { name: "mine" }
    token = JSON.parse(response.body).dig("api_key", "token")
    # Agents are owned per user in this configuration; the dummy app's
    # account is a User too.
    ActionAgent::Agent.create!(name: "Records", slug: "records", provider: "mock", model: "mock", status: :active,
      user_id: account.id, account_id: account.id)
    seen = :unset

    ActionAgent::AgentExecutionService.stub(:call, ->(_agent, run) {
      seen = run.actor
      { output: "done", metadata: {}, usage: {} }
    }) do
      post "/activeagents/mcp",
        params: { jsonrpc: "2.0", id: 1, method: "tools/call",
                  params: { name: "run_records", arguments: { message: "hello" } } }.to_json,
        headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}" }
    end

    assert_response :success
    assert_nil JSON.parse(response.body)["error"]
    assert_equal me, seen
  end

  test "a key on an install without a user model records no creator" do
    post "/activeagents/api/api_keys", params: { name: "anonymous" }

    assert_response :created
    key = ActionAgent::ApiKey.find_by!(name: "anonymous")
    assert_nil key.user_id
    assert_nil key.creator
  end

  test "a key whose creator no longer exists has none" do
    ActionAgent.user_class = "User"
    gone = User.create!(email: "gone-#{SecureRandom.hex(3)}@example.com", name: "Gone", age: 30)
    key = ActionAgent::ApiKey.create!(name: "orphan", user_id: gone.id)
    gone.destroy!

    assert_nil key.reload.creator
  end

  private

  def sign_in_to_account
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "User" # the dummy app has no Account
    ActionAgent.multi_tenant = true
    me = User.create!(email: "me-#{SecureRandom.hex(3)}@example.com", name: "Me", age: 30)
    account = User.create!(email: "account-#{SecureRandom.hex(3)}@example.com", name: "Account", age: 30)
    ActionAgent.current_user_resolver = ->(_controller) { me }
    ActionAgent.current_account_resolver = ->(_controller) { account }
    [ me, account ]
  end
end
