# frozen_string_literal: true

module ActionAgent
  # Used to run the engine's explorer agent for one Exploration: an AgentRun
  # of the project's explorer agent (Project#explorer_agent!) that walks the
  # project's app in its sandbox browser and proposes the questions a user
  # of the app would ask the project's target agent.
  #
  # The run is an ordinary one, so it is traced, its tool calls are logged
  # as events and its browser actions are recorded on the browser's session
  # recording. What differs is what the model is offered:
  #
  #   browser tools      BROWSER_TOOLS of the sandbox's browser (its MCP
  #                      entry), without their file-writing arguments, and
  #                      navigation only within the app
  #   sign_in            fills the app's login form from a sign_in
  #                      ProjectSecret named by secret_ref, in the Rails
  #                      process (BrowserSignIn): the model never sees the
  #                      credentials
  #   read_last_email    the newest mail the app sent an address
  #                      (SandboxMail)
  #   propose_candidate  stores a candidate with Exploration#add_candidates!,
  #                      with the provenance filled in here: the pages and
  #                      steps since the last candidate, and their range of
  #                      the recording
  #   finish             ends the walk
  #
  # Every browser result is scrubbed of the project's secrets before the
  # model, the trace or the run's log sees it, and cut to RESULT_TEXT_LIMIT.
  #
  # The exploration's budget is checked after every tool call. Once its
  # minutes, steps or cost are used up, the results the model was answered
  # with reach CONVERSATION_LIMIT, or someone chose Stop and review, every
  # tool but finish answers that the walk is over, and a model that keeps
  # calling tools is cut short with WalkCutShort.
  class ExplorerExecutionService < AgentExecutionService
    # Raised out of the generation when the model keeps calling tools after
    # the walk ended. #reason is why it ended.
    class WalkCutShort < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super("The explorer kept calling tools after the exploration ended (#{reason})")
      end
    end

    # The network tools are left out: a page's request list keeps the
    # sign-in form's POST body, password included, until the next
    # navigation.
    BROWSER_TOOLS = %w[
      browser_navigate browser_navigate_back browser_snapshot browser_find browser_click browser_type browser_fill_form
      browser_select_option browser_press_key browser_hover browser_wait_for browser_tabs browser_handle_dialog
      browser_take_screenshot browser_console_messages browser_generate_locator
    ].freeze
    BROWSER_TOOL_PREFIX = "browser_verify_"
    # Arguments that make a browser tool write its output to a file in the
    # sidecar instead of answering with it.
    FILE_ARGUMENTS = %w[filename].freeze
    # The tools that open a URL, and the argument holding it.
    NAVIGATION_TOOLS = { "browser_navigate" => :url, "browser_tabs" => :url }.freeze
    # Calls a model may make after the walk ended before it is cut short.
    CALLS_AFTER_END = 5
    # Tool turns the provider allows beyond the step budget, for the
    # explorer's own tools.
    TOOL_TURN_MARGIN = 60
    ROSTER_DESCRIPTION_LIMIT = 200
    ROSTER_TOOL_LIMIT = 100
    # Characters of a browser result the model sees; the rest of a long
    # page snapshot is cut.
    RESULT_TEXT_LIMIT = 24_000
    # Characters of tool results, in all, after which the walk ends. Every
    # result stays in the conversation, so this keeps it within a model's
    # context window (about 100,000 tokens), and the walk ends in review
    # rather than failing on an overlong request.
    CONVERSATION_LIMIT = 400_000

    END_MESSAGES = {
      "finished" => "You called finish.",
      "budget_minutes" => "The exploration's time budget is used up.",
      "budget_steps" => "The exploration's browser step budget is used up.",
      "budget_cost" => "The exploration's cost budget is used up.",
      "budget_context" => "The exploration's conversation is full.",
      "stopped" => "The exploration was stopped for review."
    }.freeze

    TOOL_DEFINITIONS = [
      {
        name: "sign_in",
        description: "Signs the browser in to the app with saved credentials. You never see or type them: name the " \
                     "credentials with secret_ref. Answers whether the browser left the login page; \"unsupported\" " \
                     "means the app has no password sign-in the sandbox can use.",
        parameters: {
          type: "object",
          properties: { secret_ref: { type: "string", description: "The name of the saved sign-in to use" } },
          required: [ "secret_ref" ]
        }
      },
      {
        name: "read_last_email",
        description: "Reads the newest email the app sent to an address, such as a sign-up's verification email: its " \
                     "subject, sender, text and links. Open a link by navigating to its path. Empty when none was sent.",
        parameters: {
          type: "object",
          properties: { to: { type: "string", description: "The recipient's email address" } },
          required: [ "to" ]
        }
      },
      {
        name: "propose_candidate",
        description: "Proposes one evaluation scenario: a question a user of the page you just explored would ask " \
                     "the assistant, in the user's own words, with a rubric for a good answer. Never put steps, " \
                     "selectors or URLs in it; where you found it is recorded for you.",
        parameters: {
          type: "object",
          properties: {
            prompt: { type: "string", description: "The user's question" },
            group: { type: "string", description: "The part of the app it is about, such as Orders" },
            rubric: { type: "string", description: "What a good answer says or does, for the judge" },
            tools: { type: "array", items: { type: "string" }, description: "The assistant's tools a good answer needs" },
            contains: { type: "array", items: { type: "string" }, description: "Text a good answer always contains" },
            not_contains: { type: "array", items: { type: "string" }, description: "Text a good answer never contains" }
          },
          required: [ "prompt", "rubric" ]
        }
      },
      {
        name: "finish",
        description: "Ends the exploration. Call it once you have explored the app, or when told the budget is used up.",
        parameters: {
          type: "object",
          properties: { summary: { type: "string", description: "What you explored, in a sentence or two" } },
          required: []
        }
      }
    ].freeze

    # Scrubs every result its tools answer with of +secrets+ (a callable
    # returning the values), before the run records or returns it.
    class ScrubbingDispatcher < MCPToolDispatcher
      def initialize(agent, extra_server_keys:, secrets:)
        super(agent, extra_server_keys: extra_server_keys)
        @secrets = secrets
      end

      def call(tool_name, arguments = {})
        result = super
        result && SecretScrubber.scrub(result, @secrets.call)
      end
    end

    # @param exploration [Exploration] a project's explorer exploration,
    #   with its sandbox set
    # @param run [AgentRun] its run, of the project's explorer agent
    def initialize(exploration, run)
      super(run.agent, run)
      @exploration = exploration
      @project = exploration.project
      @sandbox = exploration.sandbox_session
      @steps = 0
      @cost = 0.0
      @answered = 0
      @calls_after_end = 0
      @ended = nil
      @summary = nil
      @walk_started = monotonic
      start_segment
    end

    # Opens the project's start URL in the browser and runs the explorer.
    # Returns AgentExecutionService#call's result with :stop_reason, why the
    # walk ended, and :summary, what the explorer said it explored.
    #
    # @raise [WalkCutShort]
    # @return [Hash]
    def walk!
      subscription = ActiveSupport::Notifications.subscribe("prompt.provider.active_agent") do |*, payload|
        meter_cost(payload)
      end
      open_start_url
      result = call
      result.merge(stop_reason: @ended || "finished", summary: @summary)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    end

    # Runs a tool as AgentExecutionService does, then checks the budget. A
    # model that keeps calling tools after the walk ended is cut short.
    def execute_tool(name, **kwargs)
      result = super
      @answered += result.to_json.length
      check_budget!
      raise WalkCutShort, @ended if @ended && @calls_after_end > CALLS_AFTER_END

      result
    end

    # The instructions the explorer runs under: how to walk the app, and
    # the target agent's tools, which candidates are checked against.
    def composed_instructions
      @composed_instructions ||= <<~TEXT
        You explore #{@project.repository}, a web application running in a sandbox, through its browser. You find
        the questions a user of the app would ask #{target_agent_name}, an AI assistant for the app, and propose
        each one with propose_candidate.

        #{target_tools_text}

        Work in a loop:
        1. Take a snapshot of the page (browser_snapshot).
        2. Choose a part of the app you have not explored yet: a page, a list, a filter, a detail view or a form.
        3. Open it with the browser tools. Navigate with paths on the app, such as /orders.
        4. Note what the page shows a user and lets them do, then propose the questions a user of that page would
           ask the assistant. Give each a rubric that says what a good answer contains, and the assistant's tools a
           good answer needs.

        Candidates are questions for the assistant, not click scripts: never write steps, selectors or URLs into a
        prompt or rubric. Where you found each candidate is recorded for you. Prefer questions the assistant's tools
        can answer, and propose a question its tools cannot answer only when a user would clearly ask it.

        #{sign_in_text}

        When the app sends an email, such as a verification link, read it with read_last_email and open the link's
        path. If you are stuck, for example on a CAPTCHA, call finish and say so.

        Your budget is #{budget['steps']} browser steps and #{budget['minutes']} minutes. When a tool answers that the
        exploration has ended, call finish. Call finish with a short summary once you have explored the app.
      TEXT
    end

    private

    def generation_options
      { max_tool_turns: budget["steps"].to_i + TOOL_TURN_MARGIN }
    end

    def tool_schema_halves
      @tool_schema_halves ||= [ browser_tool_definitions, TOOL_DEFINITIONS ]
    end

    def browser_tool_definitions
      mcp_dispatcher.tool_definitions.filter_map do |definition|
        next unless browser_tool?(definition[:name])

        parameters = definition[:parameters].deep_dup
        properties = parameters[:properties] || parameters["properties"]
        FILE_ARGUMENTS.each { |argument| properties&.delete(argument) || properties&.delete(argument.to_sym) }
        definition.merge(parameters: parameters)
      end
    end

    def mcp_dispatcher
      @mcp_dispatcher ||= ScrubbingDispatcher.new(@agent_record, extra_server_keys: [ @sandbox.browser_server_key ],
        secrets: -> { explorer_secrets })
    end

    def browser_recorder
      @browser_recorder ||= MCPRecordingMiddleware.new(session_recording: @exploration.session_recording, agent_run: @run,
        secrets: -> { recording_secrets })
    end

    def recording_secrets
      super + explorer_secrets
    end

    # The project's secrets with their encodings and the sandbox's tokens.
    def explorer_secrets
      @explorer_secrets ||= [ *@project.scrub_values, @sandbox.runtime_mcp_token, @sandbox.browser_token ].compact
    end

    # The optional third argument matches the dashboard input-request dispatch,
    # which passes the tool call's id; the explorer has no use for it.
    def dispatch_tool(name, kwargs, _tool_call_id = nil)
      name = name.to_s
      if @ended && name != "finish"
        @calls_after_end += 1
        return { error: "#{END_MESSAGES.fetch(@ended)} Call finish now." }
      end

      case name
      when "sign_in" then sign_in(kwargs[:secret_ref])
      when "read_last_email" then read_last_email(kwargs[:to])
      when "propose_candidate" then propose_candidate(kwargs)
      when "finish" then finish(kwargs[:summary])
      else
        refusal = browser_refusal(name, kwargs)
        return refusal if refusal

        @steps += 1
        note_step(name, kwargs)
        result = browser_call(name, kwargs.except(*FILE_ARGUMENTS.map(&:to_sym)))
        note_page(result)
        cut(result)
      end
    end

    def cut(result)
      text = result.is_a?(Hash) ? result[:text] : nil
      return result unless text.is_a?(String) && text.length > RESULT_TEXT_LIMIT

      result.merge(text: "#{text[0, RESULT_TEXT_LIMIT]}\n# … (cut, #{text.length} characters in all)")
    end

    # Calls browser tool +name+ on the sandbox's browser, recorded on the
    # recording. A tool the browser does not serve is an error: the
    # explorer never falls back to the toolbox's browser.
    def browser_call(name, kwargs)
      browser_recorder.intercept(tool_name: name, parameters: kwargs) do
        mcp_dispatcher.call(name, kwargs) || { error: "#{name} is not one of the sandbox browser's tools" }
      end
    end

    def browser_tool?(name)
      BROWSER_TOOLS.include?(name.to_s) || name.to_s.start_with?(BROWSER_TOOL_PREFIX)
    end

    # Why the explorer may not make browser call +name+, or nil.
    def browser_refusal(name, kwargs)
      return { error: "#{name} is not one of the explorer's tools" } unless browser_tool?(name)

      navigation_refusal(name, kwargs)
    end

    # The browser may only open the app: a path, or a URL on the app's
    # origin. The sidecar enforces the same pin.
    def navigation_refusal(name, kwargs)
      argument = NAVIGATION_TOOLS[name]
      return nil unless argument

      url = kwargs[argument].to_s
      return nil if url.empty? || app_url?(url)

      { error: "The explorer stays on the app: open a path on it, such as /orders" }
    end

    def app_url?(url)
      return url.start_with?("/") && !url.start_with?("//") unless url.match?(%r{\A[a-z][a-z0-9+.-]*:}i)

      app = URI.parse(@sandbox.cloud_run_url.to_s)
      target = URI.parse(url)
      [ target.scheme, target.host, target.port ] == [ app.scheme, app.host, app.port ]
    rescue URI::Error
      false
    end

    def sign_in(secret_ref)
      @steps += 1
      name = secret_ref.to_s
      secret = @project.secrets.sign_in.find_by(name: name)
      unless secret
        return { error: "No saved sign-in is named #{name.truncate(60)}", available: @project.sign_in_secret_names }
      end

      note_step("sign_in", element: name)
      result = BrowserSignIn.call(@sandbox, secret).to_h
      note_page({ text: "- Page URL: #{current_page_url}" }) if result[:signed_in]
      result
    end

    def current_page_url
      SandboxBrowserDriver.new(@sandbox).current_path
    rescue SandboxBrowserDriver::Error
      nil
    end

    def read_last_email(to)
      message = SandboxMail.last_message(@sandbox, to: to, secrets: explorer_secrets)
      message.empty? ? { email: nil, note: "No email was sent to #{to.to_s.truncate(100)} yet" } : { email: message }
    rescue ArgumentError, SandboxMail::Unsupported, SandboxOrchestrator::UnsupportedBackendError => e
      { error: e.message }
    end

    def propose_candidate(kwargs)
      raw = kwargs.to_h.stringify_keys.slice("prompt", "group", "rubric", "tools", "contains", "not_contains")
      stored = @exploration.add_candidates!([ raw.merge("provenance" => segment_provenance) ], roster: roster).first
      start_segment
      { proposed: true, id: stored["id"], verdict: stored["verdict"], missing_tools: stored["missing_tools"] }
    rescue Exploration::InvalidCandidate, Exploration::CandidateLimitExceeded => e
      { error: e.message }
    end

    def finish(summary)
      @ended ||= "finished"
      @summary = summary.to_s.truncate(2_000).presence
      { finished: true }
    end

    # The target agent's tools, read once, with the project's sandbox and
    # its browser attached: candidates are checked against them, and the
    # instructions list them. Nil when they cannot be read.
    def target_roster
      return @target_roster if defined?(@target_roster)

      agent = @exploration.target_agent
      extra = [ @sandbox.runtime_server_key, (@sandbox.browser_server_key if @sandbox.browser_running?) ].compact
      @target_roster = agent && RuntimeToolRoster.new(agent, extra_server_keys: extra).tap(&:tools)
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] exploration #{@exploration.id}: could not list the target agent's tools: #{e.class}")
      @target_roster = nil
    end

    # The roster as Exploration.verdict reads it.
    def roster
      target_roster && { names: target_roster.tools.keys.to_set, complete: target_roster.discovery_errors.empty? }
    end

    def target_tools
      target_roster&.tools
    end

    def target_agent_name
      @exploration.target_agent&.name || "the app's assistant"
    end

    def target_tools_text
      tools = target_tools
      return "The assistant's tools could not be read, so propose the questions a user would ask about each page." if tools.blank?

      lines = tools.first(ROSTER_TOOL_LIMIT).map do |name, description|
        "- #{name}: #{description.to_s.squish.truncate(ROSTER_DESCRIPTION_LIMIT)}"
      end
      "The assistant can call these tools:\n#{lines.join("\n")}"
    end

    def sign_in_text
      names = @project.sign_in_secret_names
      if names.any?
        "If the app asks you to sign in, call sign_in with secret_ref #{names.map { |name| "\"#{name}\"" }.join(' or ')}. " \
          "Never type a password yourself."
      elsif @project.saved_storage_state
        "The browser starts signed in. Never type a password yourself."
      else
        "No sign-in is set up for this app, so explore what is reachable without one. Never type a password yourself."
      end
    end

    def budget
      @budget ||= Exploration::DEFAULT_BUDGET.merge(@exploration.budget.slice(*Exploration::BUDGET_KEYS))
    end

    def open_start_url
      SandboxBrowserDriver.new(@sandbox).open(@project.start_url.presence || "/")
      note_page({ text: "- Page URL: #{@project.start_url.presence || '/'}" })
    rescue SandboxBrowserDriver::Error => e
      Rails.logger.warn("[ActionAgent] exploration #{@exploration.id}: could not open the start URL: #{e.message}")
    end

    def check_budget!
      minutes = (monotonic - @walk_started) / 60.0
      @exploration.record_usage!(minutes: minutes, steps: @steps, cost: @cost)
      @ended ||= "stopped" unless @exploration.walking?
      @ended ||= "budget_steps" if @steps >= budget["steps"].to_i
      @ended ||= "budget_minutes" if minutes >= budget["minutes"].to_f
      @ended ||= "budget_cost" if budget["cost"].present? && @cost >= budget["cost"].to_f
      @ended ||= "budget_context" if @answered >= CONVERSATION_LIMIT
    end

    def meter_cost(payload)
      return unless payload.is_a?(Hash) && payload[:trace_id] == @run.trace_id

      usage = payload[:usage] || {}
      @cost += ModelPricing.estimate(model: payload[:model].presence || model, provider: requested_provider,
        input_tokens: usage[:input_tokens], output_tokens: usage[:output_tokens]).to_f
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] exploration #{@exploration.id}: could not price a generation: #{e.class}")
    end

    # --- provenance -----------------------------------------------------

    def start_segment
      @segment = { started_at: Time.current, steps: [], urls: [] }
    end

    def note_step(name, kwargs)
      target = kwargs[:element] || kwargs[:url] || kwargs[:key]
      step = [ name.to_s.delete_prefix("browser_").tr("_", " "), target.to_s.squish.truncate(120).presence ].compact.join(": ")
      @segment[:steps] = (@segment[:steps] + [ step ]).last(Exploration::MAX_ITEMS)
    end

    def note_page(result)
      text = result.is_a?(Hash) ? (result[:text] || result["text"]).to_s : ""
      url = text[SandboxBrowserDriver::PAGE_URL, 1]
      return if url.blank?

      path = app_path(url)
      @segment[:urls] = (@segment[:urls] | [ path ]).last(Exploration::MAX_ITEMS)
    end

    # +url+ as a path on the app, or as given when it is not one.
    def app_path(url)
      return url if url.start_with?("/")

      uri = URI.parse(url)
      app_url?(url) ? [ uri.path.presence || "/", uri.query ].compact.join("?") : url
    rescue URI::Error
      url
    end

    def segment_provenance
      recording = @exploration.session_recording
      provenance = { "urls" => @segment[:urls], "steps" => @segment[:steps] }
      return provenance unless recording

      origin = recording.created_at
      provenance.merge(
        "recording_id" => recording.id,
        "range" => {
          "from_ms" => [ ((@segment[:started_at] - origin) * 1000).floor, 0 ].max,
          "to_ms" => [ ((Time.current - origin) * 1000).ceil, 0 ].max
        }
      )
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
