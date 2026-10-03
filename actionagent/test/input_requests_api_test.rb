# frozen_string_literal: true

require "test_helper"

# Stored requests for input and the endpoints that answer them: who sees a
# request, who may answer it, and what an answer may be. The runs here are
# put in their paused state directly; input_requests_execution_test.rb pauses
# and resumes real generations.
class InputRequestsApiTest < ActionDispatch::IntegrationTest
  CHECKPOINT = { "version" => 1, "messages" => [ { "role" => "assistant", "content" => "asking" } ] }.freeze

  def setup
    ActionAgent::Agent.delete_all
    ActionAgent::ApiKey.delete_all
    @agent = ActionAgent::Agent.create!(name: "Concierge", slug: "concierge", provider: "mock", model: "mock-model", status: :active)
  end

  def teardown
    ActionAgent.user_class = nil
    ActionAgent.account_class = nil
    ActionAgent.multi_tenant = false
    ActionAgent.current_user_resolver = nil
    ActionAgent.current_account_resolver = nil
    ActionAgent.permission_checker = nil
    ActionAgent.input_request_ttl = 1.day
  end

  # A run of +agent+ paused on +requests+, one InputRequest per
  # ActiveAgent::InputRequest given.
  def paused_run(*requests, agent: @agent)
    run = agent.agent_runs.create!(trace_id: SecureRandom.uuid, status: :running, input_prompt: "Plan my trip", started_at: Time.current)
    requests = [ ActiveAgent::InputRequest.text("Where to?") ] if requests.empty?
    requests = requests.each_with_index.map { |request, index| request.for_tool_call(id: "toolu_#{index + 1}", name: "ask_user") }
    run.record_result!({ metadata: {}, usage: {}, input_requests: requests, checkpoint: CHECKPOINT }, segment_started_at: run.started_at)
    run
  end

  def answer(request, value, **options)
    post "/activeagents/api/input_requests/#{request.id}/answer", params: { answer: value }, as: :json, **options
  end

  def json
    JSON.parse(response.body)
  end

  test "the model owns requests by account first, and copies its owner from the run's agent" do
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "User" # the dummy app has no Account
    assert_equal :account, ActionAgent::InputRequest.owner_association

    @agent.update_columns(user_id: 41, account_id: 42)
    request = paused_run.input_requests.sole

    assert_equal [ 42, 41 ], [ request.account_id, request.user_id ]
  end

  test "the approval list is part of the agent's versioned configuration" do
    patch "/activeagents/api/agents/#{@agent.id}", params: { agent: { approval_required_tools: %w[calculate calculate fetch_url] } }, as: :json

    assert_response :success
    assert_equal %w[calculate fetch_url], @agent.reload.approval_required_tools
    version = @agent.latest_version
    assert_equal 2, version.version_number
    assert_equal %w[calculate fetch_url], version.configuration_snapshot["approval_required_tools"]

    @agent.restore_from_version!(@agent.agent_versions.find_by!(version_number: 1))
    assert_empty @agent.reload.approval_required_tools
  end

  test "a pause stores one request per paused call, sharing a pause key and the checkpoint" do
    run = paused_run(ActiveAgent::InputRequest.text("Where to?"), ActiveAgent::InputRequest.choice("Class?", options: %w[economy business]))

    assert run.awaiting_input?
    requests = run.input_requests.order(:id).to_a
    assert_equal %w[text choice], requests.map(&:kind)
    assert_equal 1, requests.map(&:pause_key).uniq.size
    assert_equal [ CHECKPOINT ] * 2, requests.map(&:checkpoint_data)
    assert_in_delta 1.day.from_now, requests.first.expires_at, 5
  end

  test "the checkpoint and the answer are encrypted at rest" do
    request = paused_run.input_requests.sole
    request.answer!("Lisbon")

    raw = ActiveRecord::Base.connection.select_one(
      "SELECT answer, checkpoint FROM #{ActionAgent::InputRequest.quoted_table_name} WHERE id = #{request.id}"
    )
    assert_not_includes raw["answer"].to_s, "Lisbon"
    assert_not_includes raw["checkpoint"].to_s, "asking"
    assert_equal "Lisbon", request.reload.answer
  end

  test "the list shows pending requests, filtered by run and agent, without answers or checkpoints" do
    run = paused_run(ActiveAgent::InputRequest.secret("Paste the token"))
    other = paused_run
    other.input_requests.sole.answer!("Porto")

    get "/activeagents/api/input_requests"

    assert_response :success
    entries = json["input_requests"]
    assert_equal [ run.input_requests.sole.id ], entries.map { |entry| entry["id"] }
    entry = entries.sole
    assert_equal({ "id" => @agent.id, "name" => "Concierge", "slug" => "concierge" }, entry["agent"])
    assert_equal [ run.id, "secret", "Paste the token", "ask_user" ], entry.values_at("run_id", "kind", "prompt", "tool_name")
    assert_empty entry.keys & %w[answer checkpoint]

    get "/activeagents/api/input_requests", params: { status: "all", run_id: other.id }
    assert_equal [ "answered" ], json["input_requests"].map { |item| item["status"] }
    assert_not_includes response.body, "Porto"
    assert_not_includes response.body, "asking"

    get "/activeagents/api/input_requests", params: { agent_id: @agent.id + 1 }
    assert_empty json["input_requests"]

    get "/activeagents/api/runs/#{run.id}"
    assert_equal [ entry["id"] ], json.dig("run", "input_requests").map { |item| item["id"] }
  end

  test "a confirm request carries the paused call's arguments" do
    run = paused_run(ActiveAgent::InputRequest.confirm("Allow refund to run?", metadata: { arguments: { order_id: 7 } }))

    get "/activeagents/api/input_requests"

    assert_equal({ "order_id" => 7 }, json["input_requests"].sole["arguments"])
    assert_equal({ "order_id" => 7 }, run.input_requests.sole.arguments)
  end

  test "answering the last request of a pause enqueues one resume, with the request id as its only argument" do
    run = paused_run(ActiveAgent::InputRequest.text("Where to?"), ActiveAgent::InputRequest.text("When?"))
    first, second = run.input_requests.order(:id).to_a

    assert_no_enqueued_jobs(only: ActionAgent::AgentResumeJob) { answer(first, "Lisbon") }
    assert_response :success
    assert_equal "answered", json.dig("input_request", "status")

    assert_enqueued_with(job: ActionAgent::AgentResumeJob, args: [ second.id ]) do
      post "/activeagents/api/input_requests/#{second.id}/decline", as: :json
    end
    assert_response :success
    assert second.reload.declined?
    assert_equal [ "Lisbon", false ], [ first.reload.resume_answer, second.resume_answer ]
  end

  test "a second answer to the same request is a conflict" do
    request = paused_run.input_requests.sole
    answer(request, "Lisbon")

    answer(request, "Porto")

    assert_response :conflict
    assert_equal "answered", json["status"]
    assert_equal "Lisbon", request.reload.answer
  end

  test "an answer after the request expired is a conflict, and the run fails" do
    run = paused_run(ActiveAgent::InputRequest.text("Where to?"), ActiveAgent::InputRequest.text("When?"))
    expiring, sibling = run.input_requests.order(:id).to_a
    expiring.update_columns(expires_at: 1.minute.ago)

    assert_no_enqueued_jobs { answer(expiring, "Lisbon") }

    assert_response :conflict
    assert expiring.reload.expired?
    assert sibling.reload.cancelled?
    assert run.reload.failed?
    assert_nil expiring.answer
  end

  test "a choice outside the options, or a blank answer, is unprocessable" do
    choice = paused_run(ActiveAgent::InputRequest.choice("Class?", options: [ "economy", { "value" => "business", "label" => "Business" } ])).input_requests.sole
    text = paused_run.input_requests.sole

    answer(choice, "first")
    assert_response :unprocessable_entity
    answer(text, "  ")
    assert_response :unprocessable_entity
    answer(text, { "nested" => "x" })
    assert_response :unprocessable_entity
    assert choice.reload.pending?
    assert text.reload.pending?

    answer(choice, "business")
    assert_response :success
  end

  test "a confirm request is approved by true or no answer, declined by false, and refuses anything else" do
    confirm = -> { paused_run(ActiveAgent::InputRequest.confirm("Allow refund to run?")).input_requests.sole }

    refused = confirm.call
    [ "no", "yes", "", 0, { "approved" => true } ].each do |value|
      answer(refused, value)
      assert_response :unprocessable_entity, "#{value.inspect} must not settle a confirm request"
    end
    assert refused.reload.pending?

    { true => "answered", "true" => "answered", nil => "answered", false => "declined", "false" => "declined" }.each do |value, status|
      request = confirm.call
      answer(request, value)
      assert_response :success
      assert_equal status, request.reload.status, "answering #{value.inspect}"
      assert_equal status == "answered", request.resume_answer
    end
  end

  test "a request in another account's scope is not found" do
    me, account = sign_in_to_account
    stranger = User.create!(email: "stranger-#{SecureRandom.hex(3)}@example.com", name: "Stranger", age: 30)
    @agent.update_columns(account_id: stranger.id)
    request = paused_run.input_requests.sole

    get "/activeagents/api/input_requests"
    assert_empty json["input_requests"]

    answer(request, "Lisbon")
    assert_response :not_found
    post "/activeagents/api/input_requests/#{request.id}/decline", as: :json
    assert_response :not_found
    assert request.reload.pending?

    @agent.update_columns(account_id: account.id)
    mine = paused_run.input_requests.sole
    answer(mine, "Lisbon")
    assert_response :success
    assert_equal me.id, mine.reload.answered_by_id
  end

  test "a denial from the permission checker is forbidden, and the checker sees the request" do
    request = paused_run.input_requests.sole
    asked = []
    ActionAgent.permission_checker = ->(user, action, subject) { asked << [ user, action, subject ] && false }

    answer(request, "Lisbon")

    assert_response :forbidden
    assert_equal [ [ nil, :answer_input_request, request ] ], asked
    assert request.reload.pending?
  end

  test "in multi-tenant mode a request with no signed-in user is refused, even with no checker" do
    _me, account = sign_in_to_account
    ActionAgent.current_user_resolver = ->(_controller) { nil }
    @agent.update_columns(account_id: account.id)
    request = paused_run.input_requests.sole

    answer(request, "Lisbon")

    assert_response :forbidden
    assert request.reload.pending?
  end

  test "answers are filtered from the request log" do
    request = paused_run(ActiveAgent::InputRequest.secret("Paste the token")).input_requests.sole
    logged = []
    subscriber = ActiveSupport::Notifications.subscribe("start_processing.action_controller") do |*, payload|
      logged << payload[:params]
    end

    answer(request, "sk-live-filter-me")

    assert_response :success
    assert_equal "[FILTERED]", logged.last["answer"]
    assert_not_includes logged.to_json, "sk-live-filter-me"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "cancelling a paused run cancels its pending requests" do
    run = paused_run(ActiveAgent::InputRequest.text("Where to?"), ActiveAgent::InputRequest.text("When?"))
    run.input_requests.order(:id).first.answer!("Lisbon")

    post "/activeagents/api/runs/#{run.id}/cancel", as: :json

    assert_response :success
    assert run.reload.cancelled?
    assert_equal %w[answered cancelled], run.input_requests.order(:id).map(&:status)
  end

  test "the execution job leaves a paused run alone" do
    run = paused_run
    before = run.reload.attributes

    ActionAgent::AgentExecutionJob.perform_now(run.id)

    assert_equal before, run.reload.attributes
  end

  test "the resume job does nothing until every request of the pause is settled, and then resumes once" do
    run = paused_run(ActiveAgent::InputRequest.text("Where to?"), ActiveAgent::InputRequest.text("When?"))
    first, second = run.input_requests.order(:id).to_a
    first.answer!("Lisbon")
    resumed = []
    stub_execution = lambda do |_agent, _run, resume:|
      resumed << resume
      { output: "Booked.", metadata: { "tool_calls" => [] }, usage: { input_tokens: 5, output_tokens: 3, total_tokens: 8 } }
    end

    ActionAgent::AgentExecutionService.stub(:call, stub_execution) do
      ActionAgent::AgentResumeJob.perform_now(first.id)
      assert run.reload.awaiting_input?

      second.update!(status: :answered, answer: "Friday")
      ActionAgent::AgentResumeJob.perform_now(first.id)
      ActionAgent::AgentResumeJob.perform_now(second.id)
    end

    assert_equal 1, resumed.size
    assert_equal({ "toolu_1" => "Lisbon", "toolu_2" => "Friday" }, resumed.sole[:answers])
    assert_equal CHECKPOINT, resumed.sole[:checkpoint]
    assert run.reload.complete?
    assert_equal "Booked.", run.output
  end

  test "the MCP facade lists only the key owner's requests and answers text and choice requests only" do
    me, account = sign_in_to_account
    @agent.update_columns(account_id: account.id)
    mine = paused_run(
      ActiveAgent::InputRequest.text("Where to?"), ActiveAgent::InputRequest.choice("Class?", options: %w[economy business]),
      ActiveAgent::InputRequest.confirm("Allow refund?"), ActiveAgent::InputRequest.secret("Paste the token")
    )
    other_agent = ActionAgent::Agent.create!(name: "Other", provider: "mock", model: "mock-model", account_id: me.id + 1000)
    paused_run(agent: other_agent)
    key = ActionAgent::ApiKey.create!(name: "Harness", account_id: account.id, user_id: me.id)

    listed = mcp_tool("input_requests_list", {}, key)
    assert_equal mine.input_requests.pluck(:id).sort, listed.dig("result", "structuredContent", "input_requests").map { |entry| entry["id"] }.sort
    assert_empty listed.dig("result", "structuredContent", "input_requests").flat_map(&:keys) & %w[answer checkpoint]

    text, choice, confirm, secret = mine.input_requests.order(:id).to_a
    assert_equal "answered", mcp_tool("input_requests_answer", { input_request_id: text.id, answer: "Lisbon" }, key)
      .dig("result", "structuredContent", "input_request", "status")
    assert mcp_tool("input_requests_answer", { input_request_id: choice.id, answer: "first" }, key).dig("result", "isError")
    assert_equal "Lisbon", text.reload.answer
    assert_equal me.id, text.answered_by_id

    [ confirm, secret ].each do |request|
      body = mcp_tool("input_requests_answer", { input_request_id: request.id, answer: "true" }, key)
      assert body.dig("result", "isError")
      assert_match(/answered in the dashboard/, body.dig("result", "structuredContent", "error"))
      assert request.reload.pending?
    end
  end

  private

  def mcp_tool(name, arguments, key)
    post "/activeagents/mcp",
      params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } }.to_json,
      headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{key.token}" }
    JSON.parse(response.body)
  end

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
