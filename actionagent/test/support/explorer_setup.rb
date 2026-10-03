# frozen_string_literal: true

require_relative "exploration_setup"
require_relative "../../../lib/active_agent/providers/mock_provider"

# The explorer agent's world for the tests: a project whose sandbox runs a
# browser served by FakeBrowser on the wire, a sandbox backend double
# (ExplorerBackend) that starts browsers and reads files, and a scripted
# model (ScriptedExplorer).
module ExplorerSetup
  include ExplorationSetup

  APP_URL = "http://127.0.0.1:4300"
  BROWSER_URL = "http://127.0.0.1:4400/mcp"
  BROWSER_TOKEN = "aabrw_explorerBrowserToken0123456789abcdefghij"
  SENTINEL = "Sentinel-Passw0rd-7f3c9e1a"

  # A browser's MCP endpoint that keeps a page path, answers the sign-in
  # page functions BrowserSignIn evaluates, and records every call.
  class FakeBrowser
    TOOLS = %w[
      browser_navigate browser_navigate_back browser_snapshot browser_click browser_type browser_evaluate
      browser_file_upload browser_wait_for browser_verify_text_visible
    ].freeze

    attr_reader :calls
    attr_accessor :path, :login_has_password, :signs_in, :on_call

    def initialize
      @calls = []
      @path = "/"
      @login_has_password = true
      @signs_in = true
      @typed_password = nil
    end

    def tool_calls(name = nil)
      calls.select { |call| name.nil? || call["name"] == name }
    end

    def stub!(test, token: BROWSER_TOKEN, url: BROWSER_URL)
      browser = self
      test.stub_request(:post, url).with(headers: { "Authorization" => "Bearer #{token}" }).to_return do |request|
        payload = JSON.parse(request.body)
        result =
          case payload["method"]
          when "initialize" then { protocolVersion: "2025-03-26", capabilities: { tools: {} } }
          when "tools/list"
            { tools: TOOLS.map { |name| { name: name, description: "#{name} in the browser", inputSchema: schema(name) } } }
          when "tools/call"
            browser.calls << payload["params"]
            browser.on_call&.call(payload["params"])
            { content: [ { type: "text", text: browser.answer(payload["params"]["name"], payload["params"]["arguments"] || {}) } ] }
          end

        if payload.key?("id")
          { status: 200, body: { jsonrpc: "2.0", id: payload["id"], result: result }.to_json,
            headers: { "Content-Type" => "application/json", "Mcp-Session-Id" => "browser-session" } }
        else
          { status: 202, body: "" }
        end
      end
    end

    def self.schema(name)
      properties = { "filename" => { "type" => "string" } }
      properties["url"] = { "type" => "string" } if name == "browser_navigate"
      { "type" => "object", "properties" => properties }
    end

    def schema(name) = self.class.schema(name)

    def answer(name, arguments)
      case name
      when "browser_navigate"
        self.path = URI.parse(arguments["url"].to_s).path.presence || "/"
        page
      when "browser_click"
        self.path = "/dashboard" if arguments["target"] == ActionAgent::BrowserSignIn::SUBMIT_TARGET && signs_in
        page
      when "browser_evaluate" then evaluate(arguments["function"].to_s)
      when "browser_type"
        @typed_password = arguments["text"] if arguments["target"] == ActionAgent::BrowserSignIn::PASSWORD_TARGET
        ""
      else page
      end
    end

    # A snapshot shows what a password field holds, as Playwright's does.
    def page
      text =
        if path == "/users/sign_in"
          "- textbox \"Password\" [ref=e2]#{": #{@typed_password}" if @typed_password}"
        else
          "- heading \"Page #{path}\" [ref=e1]"
        end
      "### Page\n- Page URL: #{APP_URL}#{path}\n- Page Title: Page\n### Snapshot\n```yaml\n#{text}\n```"
    end

    def evaluate(function)
      value =
        if function.include?("data-aa-sign-in")
          login_has_password ? { password: true, login: true, submit: true, path: path } : { password: false, path: path }
        elsif function.include?("location.pathname")
          path
        else
          @typed_password = nil
          true
        end
      "### Result\n#{JSON.pretty_generate(value)}"
    end
  end

  # A sandbox backend that runs browsers at FakeBrowser's endpoint and
  # serves files from FILES ({ path => content }).
  class ExplorerBackend
    class << self
      attr_accessor :launches, :stops, :files, :start_error

      def reset!
        self.launches = []
        self.stops = []
        self.files = {}
        self.start_error = nil
      end
    end
    reset!

    def create_sandbox(_session) = {}
    def status(_handle) = { status: "running" }
    def terminate(_handle) = true
    def list_sandboxes = []
    def cleanup_expired = 0
    def browser_modes = %i[headless headed]

    def start_browser(sandbox, mode:)
      raise self.class.start_error if self.class.start_error

      self.class.launches << sandbox.browser_launch.deep_dup.merge(mode: mode)
      { mcp_url: BROWSER_URL, mcp_token: BROWSER_TOKEN }
    end

    def stop_browser(sandbox)
      self.class.stops << sandbox.session_id
      true
    end

    def read_file(_session, path)
      self.class.files[path]
    end
  end

  # A model that makes each round of tool calls in turn, one round per
  # response, then answers. #script sets the rounds; #offered holds the tool
  # names each request offered, and #results what each call returned.
  class ScriptedExplorer < ActiveAgent::Providers::MockProvider
    def self.name = "ActiveAgent::Providers::MockProvider"

    class << self
      attr_accessor :rounds, :offered, :schemas, :requests, :results, :fail_after

      def script(*rounds, fail_after: nil)
        self.rounds = rounds
        self.offered = []
        self.schemas = []
        self.requests = []
        self.results = []
        self.fail_after = fail_after
      end
    end

    def api_prompt_execute(parameters)
      self.class.requests << parameters.except(:stream).to_json
      self.class.schemas << Array(parameters[:tools])
      self.class.offered << Array(parameters[:tools]).map { |tool| tool_name(tool) }
      raise "the model provider failed" if self.class.fail_after && self.class.offered.size > self.class.fail_after

      super
    end

    def process_prompt_finished_extract_function_calls
      round = self.class.rounds.shift
      round&.map { |name, arguments| { name: name.to_s, input: arguments } }
    end

    def process_function_calls(function_calls)
      function_calls.each do |function_call|
        result = tools_function.call(function_call[:name], **function_call[:input])
        self.class.results << [ function_call[:name], result ]
        message_stack.push({ role: "user", content: result.to_json })
      end
    end

    private

    def tool_name(tool)
      tool = tool.to_h if tool.respond_to?(:to_h)
      (tool[:name] || tool["name"] || tool.dig(:function, :name) || tool.dig("function", "name")).to_s
    end
  end

  def setup_explorer_world!
    reset_exploration_records!
    [ ActionAgent::AgentRun, ActionAgent::RecordingEvent, ActionAgent::SessionRecording, ActionAgent::TelemetryTrace,
      ActionAgent::AgentMessage, ActionAgent::AgentContext ].each(&:delete_all)
    ExplorerBackend.reset!
    @saved_settings = %i[sandbox_backends sandbox_service quota_checker usage_recorder execution_enabled].index_with do |name|
      ActionAgent.public_send(name)
    end
    ActionAgent.sandbox_backends = { "explorer" => ExplorerBackend.name }
    ActionAgent.sandbox_service = :explorer
    @project = create_explored_project!
    @sandbox = @project.current_sandbox_session
    @sandbox.update!(cloud_run_url: APP_URL)
    @browser = FakeBrowser.new
    stub_runtime
    @browser.stub!(self)
  end

  def restore_explorer_settings!
    @saved_settings&.each { |name, value| ActionAgent.public_send("#{name}=", value) }
  end

  def start_fake_browser!(sandbox = @sandbox)
    sandbox.update!(browser_status: "running", browser_mode: "headless", browser_mcp_url: BROWSER_URL,
      browser_token: BROWSER_TOKEN, browser_started_at: Time.current)
    ActionAgent::SessionRecording.start!(sandbox_session: sandbox, source: "agent", name: "browser")
  end

  # The explorer agent on the scripted model.
  def mock_explorer!
    @project.explorer_agent!.update!(provider: "mock", model: "mock-model")
  end

  # A pending explorer exploration of the project, with its run, as the
  # start endpoint leaves it.
  def pending_exploration!(budget: {})
    recording = ActionAgent::SessionRecording.recording.where(sandbox_session_id: @sandbox.id).last
    run = @project.explorer_agent!.agent_runs.create!(
      input_prompt: "Explore acme/shop, starting at /.", trace_id: SecureRandom.uuid, status: :pending,
      input_params: { ActionAgent::AgentRun::SANDBOX_PARAM => @sandbox.runtime_server_key,
                      ActionAgent::AgentRun::BROWSER_PARAM => @sandbox.browser_server_key }
    )
    exploration = ActionAgent::Exploration.build_for(project: @project, source: "explorer", status: "pending",
      budget: ActionAgent::Exploration.budget_from(budget))
    exploration.update!(agent_run: run, sandbox_session: @sandbox, session_recording: recording)
    exploration
  end

  # Runs ExplorationJob for +exploration+ on the scripted model.
  def walk(exploration, stop_browser: false)
    original = ActionAgent::ExplorerExecutionService.method(:new)
    ActionAgent::ExplorerExecutionService.stub(:new, ->(record, run) { original.call(record, run, provider_class: ScriptedExplorer) }) do
      ActionAgent::ExplorationJob.perform_now(exploration.id, stop_browser)
    end
    exploration.reload
  end
end
