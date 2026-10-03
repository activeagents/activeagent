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
    ActionAgent.execution_enabled = true
  end

  # A run of +agent+ for +actor+, paused on +requests+, one InputRequest per
  # ActiveAgent::InputRequest given.
  def paused_run(*requests, agent: @agent, actor: nil)
    run = agent.agent_runs.create!(
      trace_id: SecureRandom.uuid, status: :running, input_prompt: "Plan my trip", started_at: Time.current,
      input_params: ActionAgent::AgentRun.params_with_actor({}, actor)
    )
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

  test "listing requests reads neither their answers nor their checkpoints" do
    run = paused_run(ActiveAgent::InputRequest.text("Where to?"), ActiveAgent::InputRequest.text("When?"))
    key = ActionAgent::ApiKey.create!(name: "Harness")
    table = ActionAgent::InputRequest.quoted_table_name
    reads = []
    record = ->(*, payload) { reads << payload[:sql] if payload[:sql].start_with?("SELECT") && payload[:sql].include?("FROM #{table}") }

    ActiveSupport::Notifications.subscribed(record, "sql.active_record") do
      get "/activeagents/api/input_requests"
      get "/activeagents/api/runs/#{run.id}"
      get "/activeagents/api/runs"
      mcp_tool("input_requests_list", {}, key)
    end

    assert_not_empty reads
    columns = /#{Regexp.escape(table)}\.(\*|#{Regexp.escape(ActiveRecord::Base.connection.quote_column_name("checkpoint"))}|#{Regexp.escape(ActiveRecord::Base.connection.quote_column_name("answer"))})/
    reads.each { |sql| assert_no_match columns, sql }
    assert_equal 2, json.dig("result", "structuredContent", "input_requests").size
  end

  test "an unknown status filter is a bad request" do
    get "/activeagents/api/input_requests", params: { status: "bogus" }

    assert_response :bad_request
    assert_match(/Unknown status bogus/, json["error"])
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

  test "an overdue request is expired, and its run failed, when its run or the list is read" do
    shown = paused_run
    shown.input_requests.sole.update_columns(expires_at: 1.minute.ago)

    get "/activeagents/api/runs/#{shown.id}"

    assert_equal "failed", json.dig("run", "status")
    assert_empty json.dig("run", "input_requests")
    assert shown.input_requests.sole.expired?

    listed = paused_run(ActiveAgent::InputRequest.text("Where to?"), ActiveAgent::InputRequest.text("When?"))
    listed.input_requests.order(:id).first.update_columns(expires_at: 1.minute.ago)
    waiting = paused_run

    get "/activeagents/api/input_requests"

    assert_equal [ waiting.input_requests.sole.id ], json["input_requests"].map { |entry| entry["id"] }
    assert_equal %w[expired cancelled], listed.input_requests.order(:id).map(&:status)
    assert listed.reload.failed?
    assert_equal "An input request expired before it was answered", listed.error_message
    assert waiting.reload.awaiting_input?
  end

  test "the expiry job expires the overdue requests nobody read" do
    overdue = paused_run
    overdue.input_requests.sole.update_columns(expires_at: 1.minute.ago)
    waiting = paused_run
    unlimited = paused_run
    unlimited.input_requests.sole.update_columns(expires_at: nil)

    ActionAgent::InputRequestExpiryJob.perform_now

    assert overdue.input_requests.sole.expired?
    assert overdue.reload.failed?
    assert [ waiting, unlimited ].all? { |run| run.reload.awaiting_input? && run.input_requests.sole.pending? }
  end

  test "a decline after the request expired is a conflict, and the run fails" do
    run = paused_run
    request = run.input_requests.sole
    request.update_columns(expires_at: 1.minute.ago)

    assert_no_enqueued_jobs { post "/activeagents/api/input_requests/#{request.id}/decline", as: :json }

    assert_response :conflict
    assert_equal "expired", json["status"]
    assert run.reload.failed?
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

  test "a secret shorter than the minimum length is unprocessable" do
    request = paused_run(ActiveAgent::InputRequest.secret("Paste the token")).input_requests.sole

    answer(request, "x" * (ActionAgent::InputRequest::SECRET_MIN_LENGTH - 1))
    assert_response :unprocessable_entity
    assert_match(/at least #{ActionAgent::InputRequest::SECRET_MIN_LENGTH} characters/, json["error"])
    assert request.reload.pending?

    answer(request, "x" * ActionAgent::InputRequest::SECRET_MIN_LENGTH)
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
    give(@agent, stranger.id)
    request = paused_run.input_requests.sole

    get "/activeagents/api/input_requests"
    assert_empty json["input_requests"]

    answer(request, "Lisbon")
    assert_response :not_found
    post "/activeagents/api/input_requests/#{request.id}/decline", as: :json
    assert_response :not_found
    assert request.reload.pending?

    give(@agent, account.id)
    mine = paused_run.input_requests.sole
    answer(mine, "Lisbon")
    assert_response :success
    assert_equal me.id, mine.reload.answered_by_id
  end

  test "a request is found through its run, for an agent created through the API" do
    me, account = sign_in_to_account
    post "/activeagents/api/agents", params: { agent: { name: "Planner", provider: "mock", model: "mock-model" } }, as: :json
    assert_response :success
    run = paused_run(agent: ActionAgent::Agent.find(json.dig("agent", "id")))
    request = run.input_requests.sole

    get "/activeagents/api/input_requests"
    assert_equal [ request.id ], json["input_requests"].map { |entry| entry["id"] }
    get "/activeagents/api/runs/#{run.id}"
    assert_equal [ request.id ], json.dig("run", "input_requests").map { |entry| entry["id"] }
    key = ActionAgent::ApiKey.create!(name: "Harness", account_id: account.id, user_id: me.id)
    listed = mcp_tool("input_requests_list", {}, key).dig("result", "structuredContent", "input_requests")
    assert_equal [ request.id ], listed.map { |entry| entry["id"] }

    answer(request, "Lisbon")
    assert_response :success
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
    give(@agent, account.id)
    request = paused_run.input_requests.sole

    answer(request, "Lisbon")

    assert_response :forbidden
    assert request.reload.pending?
  end

  test "in multi-tenant mode with no checker, only the run's actor answers its request" do
    me, account = sign_in_to_account
    give(@agent, account.id)
    teammate = User.create!(email: "teammate-#{SecureRandom.hex(3)}@example.com", name: "Teammate", age: 30)
    request = paused_run(ActiveAgent::InputRequest.confirm("Allow refund to run?"), actor: teammate).input_requests.sole
    assert_equal teammate.id, request.requested_by_id

    answer(request, true)
    assert_response :forbidden
    post "/activeagents/api/input_requests/#{request.id}/decline", as: :json
    assert_response :forbidden
    text = paused_run(actor: teammate).input_requests.sole
    key = ActionAgent::ApiKey.create!(name: "Harness", account_id: account.id, user_id: me.id)
    assert mcp_tool("input_requests_answer", { input_request_id: text.id, answer: "Lisbon" }, key).dig("result", "isError")
    assert [ request, text ].all? { |pending| pending.reload.pending? }

    unattributed = paused_run.input_requests.sole
    answer(unattributed, "Lisbon")
    assert_response :success

    ActionAgent.current_user_resolver = ->(_controller) { teammate }
    answer(request, true)
    assert_response :success
    assert_equal teammate.id, request.reload.answered_by_id
  end

  test "a permission checker decides who answers, whoever the run's actor is" do
    me, account = sign_in_to_account
    give(@agent, account.id)
    teammate = User.create!(email: "teammate-#{SecureRandom.hex(3)}@example.com", name: "Teammate", age: 30)
    request = paused_run(actor: teammate).input_requests.sole
    ActionAgent.permission_checker = ->(_user, action, _subject) { action == :answer_input_request }

    answer(request, "Lisbon")

    assert_response :success
    assert_equal me.id, request.reload.answered_by_id
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

  test "only parameters named answer or value are filtered, at any depth" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    params = {
      "answer" => "a", "Value" => "v", "evaluation" => { "value" => "n" },
      "values" => "x", "default_value" => "d", "expected_answer" => "e"
    }

    assert_equal(
      {
        "answer" => "[FILTERED]", "Value" => "[FILTERED]", "evaluation" => { "value" => "[FILTERED]" },
        "values" => "x", "default_value" => "d", "expected_answer" => "e"
      },
      filter.filter(params)
    )
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

  test "the MCP answer tool asks the permission checker, as the key's user" do
    me, account = sign_in_to_account
    give(@agent, account.id)
    request = paused_run.input_requests.sole
    key = ActionAgent::ApiKey.create!(name: "Harness", account_id: account.id, user_id: me.id)
    asked = []
    ActionAgent.permission_checker = ->(user, action, subject) { asked << [ user, action, subject ] && false }

    body = mcp_tool("input_requests_answer", { input_request_id: request.id, answer: "Lisbon" }, key)

    assert body.dig("result", "isError")
    assert_match(/do not have permission/, body.dig("result", "structuredContent", "error"))
    assert_equal [ [ me, :answer_input_request, request ] ], asked
    assert request.reload.pending?
  end

  test "with agent execution disabled, nothing settles a pause or resumes its run" do
    request = paused_run.input_requests.sole
    key = ActionAgent::ApiKey.create!(name: "Harness")
    ActionAgent.execution_enabled = false

    answer(request, "Lisbon")
    assert_response :forbidden
    post "/activeagents/api/input_requests/#{request.id}/decline", as: :json
    assert_response :forbidden
    body = mcp_tool("input_requests_answer", { input_request_id: request.id, answer: "Lisbon" }, key)
    assert_match(/execution is disabled/, body.to_json)
    assert request.reload.pending?

    request.update!(status: :answered, answer: "Lisbon")
    ActionAgent::AgentExecutionService.stub(:call, ->(*) { flunk "the model must not be called" }) do
      ActionAgent::AgentResumeJob.perform_now(request.id)
    end

    run = request.subject.reload
    assert run.failed?
    assert_equal "Agent execution is disabled on this dashboard", run.error_message
  end

  test "the MCP facade lists only the key owner's requests and answers text and choice requests only" do
    me, account = sign_in_to_account
    give(@agent, account.id)
    mine = paused_run(
      ActiveAgent::InputRequest.text("Where to?"), ActiveAgent::InputRequest.choice("Class?", options: %w[economy business]),
      ActiveAgent::InputRequest.confirm("Allow refund?"), ActiveAgent::InputRequest.secret("Paste the token")
    )
    other_agent = ActionAgent::Agent.create!(name: "Other", provider: "mock", model: "mock-model")
    give(other_agent, me.id + 1000)
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

  # Gives +agent+ to the owner with +owner_id+, through the column this
  # install scopes agents by.
  def give(agent, owner_id)
    agent.update_columns("#{ActionAgent::Agent.owner_association}_id" => owner_id)
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
