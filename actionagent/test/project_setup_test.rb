# frozen_string_literal: true

require "test_helper"

# A project's setup assistant: the engine-defined agent a failed boot
# starts, with exactly four tools. The model is stubbed on the wire as
# Anthropic Messages, the sandbox backend is a double that records what it
# is asked, and the boot it reports failed at db_prepare.
class ProjectSetupTest < ActionDispatch::IntegrationTest
  ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
  BASE = "/activeagents/api/projects"
  SECRET = "sk_test_setup s3cret/value+0123"
  LOG = "Preparing the database\nKeyError: key not found: \"STRIPE_API_KEY\"\n"

  class SetupBackend
    class << self
      attr_accessor :calls, :boot_state, :logs

      def reset!
        self.calls = []
        self.boot_state = nil
        self.logs = {}
      end
    end

    def create_sandbox(session, boot_config: nil)
      self.class.calls << [ :create, session.session_id, boot_config ]
      created(session)
    end

    def resume_boot(session, from:, boot_config: nil)
      self.class.calls << [ :resume_boot, session.session_id, from, boot_config ]
      created(session)
    end

    def boot_status(_session) = self.class.boot_state

    def boot_log(_session, step:, offset:, secrets:, limit: 65_536)
      text = self.class.logs[step] or return nil
      page = text.byteslice(offset, limit).to_s
      { step: step, offset: offset, next_offset: offset + page.bytesize, size: text.bytesize,
        eof: offset + page.bytesize >= text.bytesize, text: ActionAgent::SecretScrubber.scrub(page, secrets) }
    end

    def handle_for(session) = "setup-#{session.session_id}"
    def terminate(_handle) = true
    def status(_handle) = { status: "running" }
    def list_sandboxes = []
    def cleanup_expired = 0

    private

    def created(session)
      { container_name: handle_for(session), url: "http://127.0.0.1:4300", mcp_url: "http://127.0.0.1:4300/activeagents/mcp",
        mcp_token: "aa_setup_runtime_token" }
    end
  end

  def setup
    [ ActionAgent::Project, ActionAgent::ProjectSecret, ActionAgent::InputRequest, ActionAgent::AgentRun, ActionAgent::EvaluationRun,
      ActionAgent::Evaluation, ActionAgent::Agent, ActionAgent::SandboxSession, ActionAgent::GithubConnection ].each(&:delete_all)
    SetupBackend.reset!
    SetupBackend.boot_state = {
      mode: "spec", kind: "bootstrap", failed_step: "db_prepare", kept: true, resumable_steps: %w[bundle_install db_prepare],
      steps: [ { name: "checkout", status: "succeeded" }, { name: "bundle_install", status: "succeeded" },
               { name: "db_prepare", status: "failed", detail: "db_prepare failed (exit 1)" } ]
    }
    SetupBackend.logs = { "db_prepare" => LOG }
    @original_backends = ActionAgent.sandbox_backends
    @original_service = ActionAgent.sandbox_service
    ActionAgent.sandbox_backends = { "setup_test" => SetupBackend.name }
    ActionAgent.sandbox_service = "setup_test"
    ActionAgent.provider_credentials_resolver = ->(_owner, provider) { provider == "anthropic" ? { access_token: "synthetic-anthropic-key" } : {} }
    ActionAgent::GithubConnection.create!(access_token: "gho_setupTestToken0123456789", github_user_id: 7, login: "octocat",
      repositories: [ { "id" => 1, "full_name" => "acme/shop", "private" => true, "default_branch" => "main" } ])
    @bodies = []
    @project = failed_project!
  end

  def teardown
    ActionAgent.sandbox_backends = @original_backends
    ActionAgent.sandbox_service = @original_service
    ActionAgent.provider_credentials_resolver = nil
    ActionAgent.permission_checker = nil
    ActionAgent.quota_checker = nil
    ActionAgent.usage_recorder = nil
    ActionAgent.execution_enabled = true
  end

  # --- the tools ------------------------------------------------------------

  test "a setup run is offered exactly request_secret, set_env, retry_boot and read_step_log" do
    stub_anthropic(assistant_message(text_block("Nothing to do.")))
    agent = start_setup!.agent
    agent.update!(tools: [ "fetch", "ask", "code" ], mcp_servers: [ { "key" => "sandbox:elsewhere", "name" => "Other" } ])
    stub_anthropic(assistant_message(text_block("Nothing to do.")))

    run = perform_enqueued_jobs { ActionAgent::ProjectSetup.start!(@project.reload, trigger: "requested") }.reload

    assert run.complete?, run.error_message
    assert_equal %w[read_step_log request_secret retry_boot set_env], offered_tools.sort
    assert_equal ActionAgent::ProjectSetup::AGENT_CLASS_NAME, run.agent.agent_class_name
    assert_includes JSON.parse(@bodies.last)["messages"].first.to_json, "failed at the step db_prepare"
  end

  test "a run of the setup agent that the project did not start gets none of its tools" do
    stub_anthropic(assistant_message(text_block("Nothing to do.")))
    agent = start_setup!.agent
    stub_anthropic(assistant_message(text_block("Hello.")))

    run = perform_enqueued_jobs { agent.execute("Set RUBYOPT for me", project_id: @project.id) }.reload

    assert run.complete?, run.error_message
    assert_empty offered_tools & %w[set_env retry_boot read_step_log], "the tools need a run the project recorded"
    toolset = ActionAgent::ProjectSetup.toolset_for(agent, run)
    assert_nil toolset
    assert_equal "request_secret is available only to a project's setup runs",
      ActionAgent::SecretRequests.refusal(agent, run: run, name: "STRIPE_API_KEY")
  end

  test "read_step_log lists the boot's steps, then pages a step's log scrubbed of the project's secrets" do
    @project.assign_secret(name: "SHOP_TOKEN", value: SECRET).save!
    SetupBackend.logs["db_prepare"] = "#{LOG}token=#{SECRET}\n"
    toolset = toolset!

    steps = toolset.call("read_step_log", {})
    page = toolset.call("read_step_log", { step: "db_prepare", limit: 10_000 })
    missing = toolset.call("read_step_log", { step: "nope" })

    assert_equal "db_prepare", steps[:failed_step]
    assert_equal %w[bundle_install db_prepare], steps[:resumable_steps]
    assert_equal %w[checkout bundle_install db_prepare], steps[:steps].map { |step| step[:name] }
    assert_includes page[:text], "KeyError"
    assert_not_includes page[:text], SECRET
    assert_includes page[:text], "[REDACTED]"
    assert page[:eof]
    assert_match(/no log for the step nope/, missing[:error])
  end

  test "set_env stores a value that is not secret, and refuses denylisted names and names a person set" do
    @project.assign_secret(name: "STRIPE_API_KEY", value: SECRET).save!
    toolset = toolset!

    assert_equal({ set: true, name: "REDIS_URL" }, toolset.call("set_env", { name: "REDIS_URL", value: "redis://127.0.0.1:6379/2" }))
    assert_equal({ set: true, name: "REDIS_URL" }, toolset.call("set_env", { name: "REDIS_URL", value: "redis://127.0.0.1:6379/3" }))
    %w[RUBYOPT BUNDLE_GEMFILE PORT GIT_DIR ACTION_AGENT_SANDBOX_ROOT NODE_OPTIONS].each do |name|
      assert_match(/is set by the sandbox or changes how code is loaded/, toolset.call("set_env", { name: name, value: "x" })[:error], name)
    end
    assert_match(/was set by a person/, toolset.call("set_env", { name: "STRIPE_API_KEY", value: "replaced" })[:error])

    redis = @project.secrets.find_by!(name: "REDIS_URL")
    assert_equal [ "setup_assistant", "redis://127.0.0.1:6379/3" ], [ redis.source, redis.value ]
    assert_equal SECRET, @project.secrets.find_by!(name: "STRIPE_API_KEY").value
    spec = @project.reload.boot_spec(@project.current_sandbox_session)
    assert_equal "redis://127.0.0.1:6379/3", spec.env["REDIS_URL"], "a value that is not secret boots unmasked"
    assert_equal SECRET, spec.secrets["STRIPE_API_KEY"]
    assert_not_includes @project.scrub_values, "redis://127.0.0.1:6379/3"
  end

  test "retry_boot resumes the kept boot from the failed step, once per run" do
    toolset = toolset!

    assert_equal true, toolset.call("retry_boot", {})[:retrying]
    perform_enqueued_jobs

    assert_equal [ :resume_boot, @project.current_sandbox_session.session_id, nil ], SetupBackend.calls.last.first(3)
    assert @project.reload.ready?
    assert_match(/retried the boot already/, toolset.call("retry_boot", {})[:error])
  end

  test "retry_boot from a named step needs one the boot can resume from" do
    toolset = toolset!

    assert_match(/manifest is not a step the boot can resume from \(bundle_install, db_prepare\)/,
      toolset.call("retry_boot", { from: "manifest" })[:error])
    assert_equal "bundle_install", toolset.call("retry_boot", { from: "bundle_install" })[:from]
    perform_enqueued_jobs

    assert_equal "bundle_install", SetupBackend.calls.last[2]
  end

  # --- request_secret -------------------------------------------------------

  test "a secret the setup assistant asks for is answered on the Project page and reaches the resumed boot, and nowhere else" do
    stub_anthropic(
      assistant_message(tool_use("toolu_1", "read_step_log", { step: "db_prepare" })),
      assistant_message(tool_use("toolu_2", "request_secret", { name: "STRIPE_API_KEY", prompt: "The app reads it at boot." })),
      assistant_message(tool_use("toolu_3", "retry_boot", {})),
      assistant_message(text_block("Retrying with the key."))
    )
    run = start_setup!.reload
    assert run.awaiting_input?, run.error_message

    get "#{BASE}/#{@project.id}/boot"
    assert_equal 1, JSON.parse(response.body).dig("project", "pending_input_requests"), "the boot status reads Waiting for you: 1"
    get "#{BASE}/#{@project.id}/input_requests"
    request = JSON.parse(response.body)["input_requests"].sole
    assert_equal [ "secret", "request_secret", run.id ], request.values_at("kind", "tool_name", "run_id")
    assert_equal "The setup assistant for acme/shop asks for STRIPE_API_KEY: The app reads it at boot. The value is stored as " \
      "one of the project's secrets and handed to acme/shop's code in its sandbox.", request["prompt"]

    post "/activeagents/api/input_requests/#{request["id"]}/answer", params: { answer: SECRET }, as: :json
    assert_response :success, response.body
    jobs = enqueued_jobs.map { |job| job[:args] }
    perform_enqueued_jobs
    perform_enqueued_jobs

    run.reload
    assert run.complete?, run.error_message
    secret = @project.secrets.find_by!(name: "STRIPE_API_KEY")
    assert_equal [ "entered", SECRET ], [ secret.source, secret.value ]
    resumed = SetupBackend.calls.find { |call| call.first == :resume_boot }
    assert resumed, SetupBackend.calls.inspect
    assert_equal SECRET, resumed[3]["secrets"]["STRIPE_API_KEY"], "the resumed boot is handed the answer"
    assert @project.reload.ready?

    recorded = {
      "provider request bodies" => @bodies,
      "trace spans" => ActionAgent::TelemetryTrace.where(trace_id: run.trace_id).pluck(:spans, :error_message),
      "run logs and metadata" => [ run.logs, run.output_metadata, run.output, run.error_message ],
      "agent messages" => ActionAgent::AgentMessage.all.map(&:attributes),
      "job arguments" => jobs + enqueued_jobs.map { |job| job[:args] },
      "the stored request" => ActionAgent::InputRequest.all.map(&:attributes)
    }
    recorded.each { |where, value| assert_not_includes value.to_json, SECRET, "the secret leaked into the #{where}" }
  end

  test "a secret name the project refuses is refused before anyone is asked" do
    stub_anthropic(
      assistant_message(tool_use("toolu_1", "request_secret", { name: "RUBYOPT", prompt: "Needed" })),
      assistant_message(text_block("I cannot set that."))
    )

    run = start_setup!.reload

    assert run.complete?, run.error_message
    assert_empty run.input_requests
    assert_includes anthropic_tool_results.fetch("toolu_1"), "changes how code is loaded"
  end

  test "answering a setup secret needs :manage_project_secrets" do
    stub_anthropic(assistant_message(tool_use("toolu_1", "request_secret", { name: "STRIPE_API_KEY", prompt: "Needed" })))
    request = start_setup!.reload.input_requests.sole
    asked = []
    ActionAgent.permission_checker = lambda do |_user, action, subject|
      asked << [ action, subject.class.name ]
      action != :manage_project_secrets
    end

    post "/activeagents/api/input_requests/#{request.id}/answer", params: { answer: SECRET }, as: :json

    assert_response :forbidden
    assert_includes asked, [ :manage_project_secrets, "ActionAgent::ProjectSecret" ]
    assert request.reload.pending?
    assert_nil @project.secrets.find_by(name: "STRIPE_API_KEY")
  end

  # --- starting it ----------------------------------------------------------

  test "a failed boot starts the setup assistant on its own, at most three times in a row, unless switched off" do
    stub_anthropic(*Array.new(4) { assistant_message(text_block("I cannot fix this one.")) })

    4.times do
      sandbox = new_failed_sandbox!
      perform_enqueued_jobs { @project.reload.sandbox_failed!(sandbox) }
    end

    assert_equal ActionAgent::ProjectSetup::MAX_AUTOMATIC_ATTEMPTS, ActionAgent::AgentRun.count
    assert_equal 3, @project.reload.setup_settings["attempts"]

    @project.sandbox_ready!(@project.current_sandbox_session.tap { |sandbox| sandbox.update!(status: :provisioning) })
    patch "#{BASE}/#{@project.id}/setup", params: { auto: false }, as: :json
    assert_response :success
    assert_equal false, JSON.parse(response.body).dig("project", "setup", "auto")
    sandbox = new_failed_sandbox!
    perform_enqueued_jobs { @project.reload.sandbox_failed!(sandbox) }

    assert_equal 3, ActionAgent::AgentRun.count, "switched off, a failed boot starts nothing"
  end

  test "while a setup run waits on a person, neither a request nor a failed boot starts another" do
    stub_anthropic(assistant_message(tool_use("toolu_1", "request_secret", { name: "STRIPE_API_KEY", prompt: "Needed" })))
    waiting = start_setup!.reload
    assert waiting.awaiting_input?, waiting.error_message

    post "#{BASE}/#{@project.id}/setup", as: :json
    assert_response :conflict
    assert_match(/waiting for an answer/, JSON.parse(response.body)["error"])
    perform_enqueued_jobs { @project.reload.sandbox_failed!(new_failed_sandbox!) }
    assert_equal [ waiting.id ], ActionAgent::AgentRun.pluck(:id)

    waiting.input_requests.sole.update!(expires_at: 1.minute.ago)
    stub_anthropic(assistant_message(text_block("Looking again.")))
    perform_enqueued_jobs { post "#{BASE}/#{@project.id}/setup", as: :json }

    assert_response :accepted, response.body
    assert waiting.reload.failed?, "the request expired, so the run it paused is over"
    assert_equal 2, ActionAgent::AgentRun.count
  end

  test "an automatic run is an execution: the host's quota can deny it, and it is counted" do
    stub_anthropic(assistant_message(text_block("I cannot fix this one.")))
    used = []
    ActionAgent.usage_recorder = ->(_owner, kind) { used << kind }
    ActionAgent.quota_checker = ->(_owner, kind) { kind == :execution ? "No executions left" : nil }

    perform_enqueued_jobs { @project.reload.sandbox_failed!(new_failed_sandbox!) }
    assert_equal 0, ActionAgent::AgentRun.count

    ActionAgent.quota_checker = nil
    perform_enqueued_jobs { @project.reload.sandbox_failed!(new_failed_sandbox!) }
    assert_equal 1, ActionAgent::AgentRun.count
    assert_equal [ :execution ], used
  end

  test "without a provider key the project says why, and asking for the assistant starts nothing" do
    ActionAgent.provider_credentials_resolver = nil
    setup = nil

    ActionAgent::AgentExecutionService.stub(:available_providers, []) do
      get "#{BASE}/#{@project.id}"
      setup = JSON.parse(response.body).dig("project", "setup")
      post "#{BASE}/#{@project.id}/setup", as: :json
    end

    assert_equal false, setup["available"]
    assert_match(/No provider key the setup assistant can use/, setup["reason"])
    assert_response :conflict
    assert_equal "setup_unavailable", JSON.parse(response.body)["code"]
    assert_equal 0, ActionAgent::AgentRun.count
  end

  test "asking for the setup assistant needs :manage_project_secrets" do
    ActionAgent.permission_checker = ->(_user, action, _subject) { action != :manage_project_secrets }

    post "#{BASE}/#{@project.id}/setup", as: :json

    assert_response :forbidden
    assert_equal 0, ActionAgent::AgentRun.count
  end

  test "asking for the setup assistant starts a run on the failed boot" do
    stub_anthropic(assistant_message(text_block("Looking.")))

    perform_enqueued_jobs { post "#{BASE}/#{@project.id}/setup", as: :json }

    assert_response :accepted
    run = ActionAgent::AgentRun.find(JSON.parse(response.body).dig("run", "id"))
    assert run.reload.complete?, run.error_message
    assert_equal run.id, @project.reload.setup_settings["last_run_id"]
    assert_equal 0, @project.setup_settings["attempts"], "a run someone asked for is not an automatic attempt"
  end

  private

  def failed_project!
    project = ActionAgent::Project.create!(name: "Shop", repository: "acme/shop", install_state: "detected",
      settings: { "preflight" => { "status" => "bootstrap" } })
    sandbox = new_failed_sandbox!(project)
    project.update!(current_sandbox_session: sandbox, status: "failed")
    project
  end

  def new_failed_sandbox!(project = @project)
    sandbox = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "acme/shop")
    sandbox.update!(project_id: project.id, status: :failed,
      error_message: "Sandbox setup failed: db_prepare exited 1\nKeyError: key not found: \"STRIPE_API_KEY\"")
    project.update!(current_sandbox_session: sandbox, status: "failed")
    sandbox
  end

  def start_setup!
    perform_enqueued_jobs { ActionAgent::ProjectSetup.start!(@project.reload, trigger: "requested") }
  end

  def toolset!
    stub_anthropic(assistant_message(text_block("Looking.")))
    run = start_setup!
    ActionAgent::ProjectSetup.toolset_for(run.agent, run) || flunk("the run has no toolset")
  end

  def offered_tools
    Array(JSON.parse(@bodies.last)["tools"]).map { |tool| tool["name"] }
  end

  def tool_use(id, name, input) = { type: "tool_use", id: id, name: name, input: input }

  def text_block(text) = { type: "text", text: text }

  def assistant_message(*content)
    stop_reason = content.any? { |block| block[:type] == "tool_use" } ? "tool_use" : "end_turn"
    { id: "msg_#{SecureRandom.hex(4)}", type: "message", role: "assistant", model: "claude-haiku-4-5",
      content: content, stop_reason: stop_reason, stop_sequence: nil, usage: { input_tokens: 20, output_tokens: 10 } }
  end

  def stub_anthropic(*messages)
    WebMock.reset!
    stub_request(:post, ANTHROPIC_URL)
      .with { |request| @bodies << request.body }
      .to_return(*messages.map { |body| { status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json } })
  end

  def anthropic_tool_results
    JSON.parse(@bodies.last)["messages"].flat_map { |turn| Array(turn["content"]) }
      .select { |block| block.is_a?(Hash) && block["type"] == "tool_result" }
      .to_h { |block| [ block["tool_use_id"], block["content"].to_json ] }
  end
end
