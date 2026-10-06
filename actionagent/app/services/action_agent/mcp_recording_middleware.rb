# frozen_string_literal: true

module ActionAgent
  # Used to record an agent's browser tool calls on a session recording.
  #
  # #intercept wraps one tool call. A Playwright MCP browser tool call is
  # stored as an `action` RecordingEvent: the tool, its parameters with the
  # typed values masked (BrowserToolRedaction) and +secrets+ scrubbed, its
  # outcome and its duration. Any other tool passes straight through and is
  # not recorded.
  #
  #   middleware = MCPRecordingMiddleware.new(agent_run: run, secrets: -> { owner_credentials })
  #   result = middleware.intercept(tool_name: "browser_type", parameters: arguments) do
  #     mcp_client.call_tool("browser_type", arguments)
  #   end
  #
  # The recording is the one given, else the live recording of the sandbox
  # session or agent run, created on the first browser call. Failing to
  # record is logged and never changes the call's result or exception.
  class MCPRecordingMiddleware
    # Map of Playwright MCP tool names to our action types
    PLAYWRIGHT_TOOLS = {
      "browser_navigate" => "navigate",
      "browser_click" => "click",
      "browser_type" => "type",
      "browser_fill_form" => "form_fill",
      "browser_press_key" => "key_press",
      "browser_snapshot" => "snapshot",
      "browser_take_screenshot" => "snapshot",
      "browser_hover" => "hover",
      "browser_select_option" => "select",
      "browser_file_upload" => "file_upload",
      "browser_handle_dialog" => "dialog",
      "browser_evaluate" => "evaluate",
      "browser_wait_for" => "wait",
      "browser_drag" => "drag",
      "browser_scroll" => "scroll"
    }.freeze

    ERROR_LIMIT = 1000

    def self.browser_tool?(tool_name)
      PLAYWRIGHT_TOOLS.key?(tool_name.to_s)
    end

    # +secrets+ is an Array of values to scrub from what is stored, or a
    # callable returning one, called on the first browser call only.
    def initialize(session_recording: nil, sandbox_session: nil, agent_run: nil, secrets: [])
      @recording = session_recording
      @sandbox_session = sandbox_session
      @agent_run = agent_run
      @secrets = secrets
    end

    # Runs the block, the tool call, and returns its result. A browser tool
    # call is recorded once it returns or raises.
    def intercept(tool_name:, parameters:)
      action_type = PLAYWRIGHT_TOOLS[tool_name.to_s]
      return (yield if block_given?) unless action_type

      started_at = Time.current
      result = nil
      error = nil
      begin
        result = yield if block_given?
      rescue StandardError => e
        error = e
        raise
      ensure
        record_action_event(tool_name.to_s, action_type, parameters, result, error, started_at)
      end
      result
    end

    # The recording this middleware writes to, or nil when there is none and
    # none could be started.
    def recording
      return @recording if @recording || @recording_resolved

      @recording_resolved = true
      @recording = find_or_create_recording
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] could not start a session recording: #{e.class}: #{e.message}")
      nil
    end

    # True once a recording has been found or started; never starts one.
    def recording_started?
      @recording.present?
    end

    def recording_service
      @recording_service ||= recording && SessionRecordingService.new(recording)
    end

    # Convenience method for recording a navigation
    def record_navigate(url:, screenshot: nil)
      recording_service&.navigate(url: url, screenshot: screenshot)
    end

    # Convenience method for recording a click
    def record_click(selector:, screenshot: nil, element_description: nil)
      recording_service&.click(
        selector: selector,
        screenshot: screenshot,
        metadata: { element: element_description }.compact
      )
    end

    # Convenience method for recording text input
    def record_type(selector:, text:, screenshot: nil)
      recording_service&.type(selector: selector, text: text, screenshot: screenshot)
    end

    # Record current page state for handoff
    def capture_for_handoff(url:, cookies: nil, local_storage: nil, form_values: nil)
      recording_service&.capture_handoff_state(
        url: url,
        cookies: cookies,
        local_storage: local_storage,
        form_values: form_values
      )
    end

    # Complete the recording
    def complete!
      recording_service&.complete!
    end

    # Fail the recording
    def fail!(error_message = nil)
      recording_service&.fail!(error_message)
    end

    private

    def find_or_create_recording
      if @sandbox_session
        SessionRecording.recording.find_by(sandbox_session: @sandbox_session) ||
          SessionRecording.start!(sandbox_session: @sandbox_session, source: "agent")
      elsif @agent_run
        SessionRecording.recording.find_by(agent_run: @agent_run) ||
          SessionRecording.start!(agent_run: @agent_run, source: "agent")
      end
    end

    def record_action_event(tool_name, action_type, parameters, result, error, started_at)
      finished_at = Time.current
      target = recording
      return unless target

      arguments = (parameters || {}).to_h.deep_stringify_keys
      failure = error&.message || result_error(result)
      data = {
        "tool_name" => tool_name,
        "action_type" => action_type,
        "parameters" => SecretScrubber.scrub(BrowserToolRedaction.redact_arguments(tool_name, arguments), secrets),
        "status" => failure ? "error" : "done",
        "error" => failure && SecretScrubber.scrub(
          BrowserToolRedaction.redact_text(tool_name, failure.to_s.truncate(ERROR_LIMIT), arguments), secrets
        ),
        "duration_ms" => ((finished_at - started_at) * 1000).round,
        "trace_id" => @agent_run&.trace_id
      }.compact

      target.record_server_event!(kind: "action", data: data, started_at: started_at, finished_at: finished_at)
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] browser action #{tool_name} not recorded: #{e.class}: #{e.message}")
    end

    # A tool that fails without raising answers with an error key.
    def result_error(result)
      return nil unless result.respond_to?(:key?)

      result[:error] || result["error"]
    end

    def secrets
      @resolved_secrets ||= Array(@secrets.respond_to?(:call) ? @secrets.call : @secrets)
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] recording secret lookup failed: #{e.class}: #{e.message}")
      @resolved_secrets = []
    end
  end
end
