# frozen_string_literal: true

require "test_helper"
require "mail"
require_relative "support/explorer_setup"

# The engine's explorer agent (ExplorerExecutionService, run by
# ExplorationJob): the tools it is offered, how it stays on the app, the
# candidates and provenance it stores, its budget and stopping, signing in
# without the model seeing the credentials, and reading the app's mail.
# The browser and the model are fakes (FakeBrowser, ScriptedExplorer).
class ExplorerAgentTest < ActiveSupport::TestCase
  include ExplorerSetup

  def setup
    setup_explorer_world!
    start_fake_browser!
    mock_explorer!
  end

  def teardown
    restore_explorer_settings!
  end

  def results_for(name)
    ScriptedExplorer.results.select { |called, _result| called.to_s == name }.map(&:last)
  end

  # What Rails.logger wrote at debug level while the block ran.
  def debug_log
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io).tap { |logger| logger.level = :debug }
    yield
    io.string
  ensure
    Rails.logger = original
  end

  test "the explorer is offered the allowlisted browser tools and its own, and none of the toolbox's" do
    ScriptedExplorer.script([ [ :browser_snapshot, {} ] ], [ [ :finish, { summary: "Looked at the home page." } ] ])

    exploration = walk(pending_exploration!)

    expected = %w[
      browser_click browser_navigate browser_navigate_back browser_snapshot browser_type browser_verify_text_visible
      browser_wait_for finish propose_candidate read_last_email sign_in
    ]
    assert_equal expected, ScriptedExplorer.offered.first.sort
    navigate = ScriptedExplorer.schemas.first.map(&:to_h).find { |tool| tool.to_json.include?("browser_navigate\"") }
    assert_not_includes navigate.to_json, "filename", "file-writing arguments are not offered"
    assert_equal [ "/" ], @browser.tool_calls("browser_navigate").map { |call| call.dig("arguments", "url") },
      "the walk starts at the project's start URL"
    assert_equal "closed", exploration.status, "nothing to review"
    assert_equal "finished", exploration.stop_reason
    run = exploration.agent_run.reload
    assert run.complete?, run.error_message
    assert_equal "Looked at the home page.", run.output_metadata["summary"]
    assert_equal 1, exploration.usage["steps"]
  end

  test "the explorer cannot navigate off the app" do
    ScriptedExplorer.script(
      [ [ :browser_navigate, { url: "https://evil.example/steal" } ] ],
      [ [ :browser_navigate, { url: "//evil.example/steal" } ] ],
      [ [ :browser_navigate, { url: "#{APP_URL}/orders" } ] ],
      [ [ :finish, {} ] ]
    )

    walk(pending_exploration!)

    refused = results_for("browser_navigate").first(2)
    assert(refused.all? { |result| result[:error].to_s.include?("stays on the app") }, refused.inspect)
    assert_equal [ "/", "#{APP_URL}/orders" ], @browser.tool_calls("browser_navigate").map { |call| call.dig("arguments", "url") }
  end

  test "a browser tool the sandbox's browser does not serve is an error, never the toolbox's browser" do
    @browser.tools = FakeBrowser::TOOLS - [ "browser_click" ]
    exploration = pending_exploration!
    service = ActionAgent::ExplorerExecutionService.new(exploration, exploration.agent_run)

    unserved, evaluate = ActionAgent::PlaywrightMCPClient.stub(:instance, -> { flunk "the shared browser was used" }) do
      [ service.send(:dispatch_tool, "browser_click", { element: "Orders", target: "e2" }),
        service.send(:dispatch_tool, "browser_evaluate", { function: "() => 1" }) ]
    end

    assert_match(/not one of the sandbox browser's tools/, unserved[:error])
    assert_match(/not one of the explorer's tools/, evaluate[:error])
    assert_empty @browser.tool_calls("browser_evaluate")
  end

  test "a proposed candidate gets a verdict against the target agent's tools and provenance from the walk" do
    ScriptedExplorer.script(
      [ [ :browser_navigate, { url: "/orders" } ] ],
      [ [ :browser_click, { element: "Late filter", target: "e3" } ] ],
      [ [ :propose_candidate, { prompt: "Which of my orders shipped late?", group: "Orders", rubric: "Lists each late order.",
                                tools: [ "find_orders" ] } ],
        [ :propose_candidate, { prompt: "Refund order A-17", rubric: "Refunds it and says so.", tools: [ "refund_order" ] } ] ],
      [ [ :finish, { summary: "Orders" } ] ]
    )

    exploration = walk(pending_exploration!)

    first, second = exploration.candidates
    assert_equal [ "answerable", "needs_tool" ], [ first["verdict"], second["verdict"] ]
    assert_equal [ "refund_order" ], second["missing_tools"]
    assert_equal "Lists each late order.", first["notes"]
    assert_equal [ "/", "/orders" ], first.dig("provenance", "urls")
    assert_equal [ "navigate: /orders", "click: Late filter" ], first.dig("provenance", "steps")
    assert_equal exploration.session_recording_id, first.dig("provenance", "recording_id")
    range = first.dig("provenance", "range")
    assert range["from_ms"] <= range["to_ms"], range.inspect
    assert_equal [], second.dig("provenance", "steps").to_a, "each candidate's steps start after the one before"
    assert_equal({ proposed: true, id: 2, verdict: "needs_tool", missing_tools: [ "refund_order" ] }, results_for("propose_candidate").last)
    assert_equal "review", exploration.status
    assert_includes exploration.agent_run.reload.logs.map { |event| event["label"] }, "propose_candidate"
  end

  test "running out of browser steps ends the walk in review with its candidates, and later tools are refused" do
    ScriptedExplorer.script(
      [ [ :browser_snapshot, {} ] ],
      [ [ :propose_candidate, { prompt: "What is on my dashboard?", rubric: "Summarizes it." } ] ],
      [ [ :browser_click, { element: "Orders", target: "e2" } ] ],
      [ [ :browser_snapshot, {} ] ],
      [ [ :finish, {} ] ]
    )

    exploration = walk(pending_exploration!(budget: { steps: 2 }))

    assert_equal "review", exploration.status
    assert_equal "budget_steps", exploration.stop_reason
    assert_equal 1, exploration.candidates.size
    assert_equal 2, exploration.usage["steps"]
    assert_match(/browser step budget is used up/, results_for("browser_snapshot").last[:error])
    assert_equal 1, @browser.tool_calls("browser_snapshot").size, "the refused snapshot never reached the browser"
    assert exploration.agent_run.reload.complete?
  end

  test "Stop and review during the walk ends it in review" do
    exploration = pending_exploration!
    @browser.on_call = ->(params) { exploration.reload.stop! if params["name"] == "browser_click" }
    ScriptedExplorer.script(
      [ [ :propose_candidate, { prompt: "Where are my invoices?", rubric: "Lists them." } ] ],
      [ [ :browser_click, { element: "Invoices", target: "e4" } ] ],
      [ [ :browser_snapshot, {} ] ],
      [ [ :finish, {} ] ]
    )

    walk(exploration)

    exploration.reload
    assert_equal "review", exploration.status
    assert_equal "stopped", exploration.stop_reason
    assert_match(/stopped for review/, results_for("browser_snapshot").last[:error])
    assert_empty @browser.tool_calls("browser_snapshot")
  end

  test "a model that keeps calling tools after the walk ended is cut short, and the walk still goes to review" do
    rounds = [ [ [ :browser_snapshot, {} ] ] ] + Array.new(8) { [ [ :browser_snapshot, {} ] ] }
    ScriptedExplorer.script(*rounds)

    exploration = walk(pending_exploration!(budget: { steps: 1 }))

    assert_equal "budget_steps", exploration.stop_reason
    assert_includes %w[review closed], exploration.status
    run = exploration.agent_run.reload
    assert run.complete?, run.error_message
    assert_match(/kept calling tools/, run.output)
    assert_equal ActionAgent::ExplorerExecutionService::CALLS_AFTER_END, results_for("browser_snapshot").count { |result| result[:error] },
      "the call after the last allowed refusal ends the generation"
  end

  test "a crash fails the walk and keeps the candidates it found" do
    ScriptedExplorer.script(
      [ [ :propose_candidate, { prompt: "What did I order last week?", rubric: "Lists last week's orders." } ] ],
      [ [ :browser_snapshot, {} ] ],
      fail_after: 2
    )

    exploration = walk(pending_exploration!)

    assert_equal "failed", exploration.status
    assert_match(/model provider failed/, exploration.error_message)
    assert_equal 1, exploration.candidates.size
    assert exploration.agent_run.reload.failed?
  end

  test "sign_in signs in with a sentinel password that appears nowhere but the browser's typing" do
    @project.assign_sign_in({ login_url: "/users/sign_in", login: "dev@example.com", password: SENTINEL }).save!
    ScriptedExplorer.script(
      [ [ :sign_in, { secret_ref: ActionAgent::Project::SIGN_IN_SECRET } ] ],
      [ [ :browser_snapshot, {} ] ],
      [ [ :propose_candidate, { prompt: "What is on my dashboard?", rubric: "Summarizes the dashboard.", tools: [ "find_orders" ] } ] ],
      [ [ :finish, { summary: "Signed in and looked at the dashboard." } ] ]
    )

    exploration = nil
    log = debug_log { exploration = walk(pending_exploration!) }

    assert_equal [ { status: "signed_in", signed_in: true, message: ActionAgent::BrowserSignIn::MESSAGES["signed_in"] } ],
      results_for("sign_in")
    typed = @browser.tool_calls("browser_type").find { |call| call.dig("arguments", "target") == ActionAgent::BrowserSignIn::PASSWORD_TARGET }
    assert_equal SENTINEL, typed.dig("arguments", "text"), "the engine typed the password into the form"
    assert_equal [ "/dashboard" ], exploration.candidates.first.dig("provenance", "urls").last(1)

    exploration.accept!([ 1 ])
    run = exploration.agent_run.reload
    stored = {
      "the run" => run.attributes.to_json,
      "the traces" => ActionAgent::TelemetryTrace.all.map(&:attributes).to_json,
      "the recording events" => ActionAgent::RecordingEvent.all.map { |event| event.events }.to_json,
      "the conversation" => ActionAgent::AgentMessage.all.map(&:attributes).to_json,
      "what the model saw" => ScriptedExplorer.requests.to_json + ScriptedExplorer.results.to_json,
      "the candidates" => exploration.reload.candidates.to_json,
      "the scenarios" => @project.reload.evaluation.scenarios.map(&:attributes).to_json,
      "the debug log" => log
    }
    stored.each { |where, text| assert_not_includes text, SENTINEL, "the password is in #{where}" }
    assert ActionAgent::TelemetryTrace.exists?, "the walk was traced"
  end

  test "a failed sign-in empties the password field, so no snapshot shows a password too short to scrub" do
    short = "Pw7#q2"
    @browser.signs_in = false
    @project.assign_sign_in({ login_url: "/users/sign_in", login: "dev@example.com", password: short }).save!
    ScriptedExplorer.script(
      [ [ :sign_in, { secret_ref: ActionAgent::Project::SIGN_IN_SECRET } ] ],
      [ [ :browser_snapshot, {} ] ],
      [ [ :finish, {} ] ]
    )

    walk(pending_exploration!)

    assert_equal "failed", results_for("sign_in").sole[:status]
    assert_nil @browser.typed_password, "the field was emptied"
    functions = @browser.tool_calls("browser_evaluate").map { |call| call.dig("arguments", "function") }
    assert_equal ActionAgent::BrowserSignIn::CLEAR_PASSWORDS, functions.last
    snapshot = results_for("browser_snapshot").sole[:text]
    assert_includes snapshot, "Page URL: #{APP_URL}/users/sign_in"
    assert_not_includes snapshot, short
  end

  test "the explorer cannot read the browser's network requests, which keep the sign-in form's body" do
    short = "Pw7#q2"
    @project.assign_sign_in({ login_url: "/users/sign_in", login: "dev@example.com", password: short }).save!
    ScriptedExplorer.script(
      [ [ :sign_in, { secret_ref: ActionAgent::Project::SIGN_IN_SECRET } ] ],
      [ [ :browser_network_requests, {} ], [ :browser_network_request, { index: 1, part: "request-body" } ] ],
      [ [ :finish, {} ] ]
    )

    walk(pending_exploration!)

    assert_not_includes ScriptedExplorer.offered.first, "browser_network_request"
    assert_not_includes ScriptedExplorer.offered.first, "browser_network_requests"
    refused = results_for("browser_network_requests") + results_for("browser_network_request")
    assert(refused.all? { |result| result[:error].to_s.include?("not one of the explorer's tools") }, refused.inspect)
    assert_empty @browser.tool_calls("browser_network_request")
    assert_not_includes ScriptedExplorer.results.to_json, short
  end

  test "sign-in is judged by the password field: a failure on another path fails, a success on the same path signs in" do
    @project.assign_sign_in({ login_url: "/users/sign_in", login: "dev@example.com", password: SENTINEL }).save!
    secret = @project.secrets.sign_in.sole

    @browser.signs_in = false
    @browser.fails_on = "/users/session"
    assert_equal "failed", ActionAgent::BrowserSignIn.call(@sandbox.reload, secret).status
    assert_nil @browser.typed_password

    @browser.signs_in = true
    @browser.lands_on = "/users/sign_in"
    assert_equal "signed_in", ActionAgent::BrowserSignIn.call(@sandbox, secret).status
  end

  test "sign_in answers unsupported when the login page has no password field, and names a missing secret" do
    @browser.login_has_password = false
    @project.assign_sign_in({ login_url: "/login", login: "dev@example.com", password: SENTINEL }).save!
    ScriptedExplorer.script(
      [ [ :sign_in, { secret_ref: ActionAgent::Project::SIGN_IN_SECRET } ], [ :sign_in, { secret_ref: "OTHER" } ] ],
      [ [ :finish, {} ] ]
    )

    walk(pending_exploration!)

    unsupported, missing = results_for("sign_in")
    assert_equal "unsupported", unsupported[:status]
    assert_match(/OAuth or SSO/, unsupported[:message])
    assert_equal [ ActionAgent::Project::SIGN_IN_SECRET ], missing[:available]
    assert_empty @browser.tool_calls("browser_type"), "nothing is typed into a page without a password field"
  end

  test "read_last_email returns the newest message for an address, and nothing when there is none" do
    first = Mail.new(from: "shop@example.com", to: "new@example.com", subject: "Welcome", body: "Hello there.").encoded
    second = Mail.new(from: "shop@example.com", to: "new@example.com", subject: "Confirm your account",
      body: "Confirm: http://localhost:3000/users/confirmation?confirmation_token=abc123\n").encoded
    ExplorerBackend.files["#{ActionAgent::SandboxMail::DIRECTORY}/new@example.com"] = "#{first}\r\n\r\n#{second}\r\n\r\n"
    ScriptedExplorer.script(
      [ [ :read_last_email, { to: "new@example.com" } ], [ :read_last_email, { to: "nobody@example.com" } ],
        [ :read_last_email, { to: "../etc/passwd" } ] ],
      [ [ :finish, {} ] ]
    )

    walk(pending_exploration!)

    newest, none, invalid = results_for("read_last_email")
    assert_equal "Confirm your account", newest.dig(:email, :subject)
    assert_equal "shop@example.com", newest.dig(:email, :from)
    assert_equal [ "/users/confirmation?confirmation_token=abc123" ], newest.dig(:email, :links).map { |link| link[:path] }
    assert_nil none[:email]
    assert_match(/email address/, invalid[:error])
  end
end
