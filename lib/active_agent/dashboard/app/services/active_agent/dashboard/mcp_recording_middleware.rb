# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Middleware for recording MCP tool calls during browser automation
    #
    # This middleware intercepts Playwright MCP tool calls and records them
    # to a SessionRecording for playback and debugging.
    #
    # Usage:
    #   middleware = MCPRecordingMiddleware.new(session_recording: recording)
    #
    #   # Process a tool call
    #   result = middleware.intercept(tool_call) do
    #     # Execute the actual MCP tool
    #     mcp_client.call_tool(tool_call)
    #   end
    #
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

      attr_reader :recording_service

      def initialize(session_recording: nil, sandbox_session: nil, agent_run: nil)
        @recording = session_recording
        @sandbox_session = sandbox_session
        @agent_run = agent_run

        # Create or find recording if not provided
        @recording ||= find_or_create_recording
        @recording_service = SessionRecordingService.new(@recording) if @recording
      end

      # Intercept an MCP tool call and record it
      def intercept(tool_name:, parameters:)
        action_type = PLAYWRIGHT_TOOLS[tool_name]

        # If not a Playwright tool, just execute and return
        unless action_type
          return yield if block_given?
          return nil
        end

        # Execute the tool
        result = nil
        screenshot = nil
        error = nil

        begin
          result = yield if block_given?

          # Extract screenshot from result if present
          screenshot = extract_screenshot(result)
        rescue => e
          error = e.message
          raise
        ensure
          # Record the action
          record_action(action_type, tool_name, parameters, result, screenshot, error)
        end

        result
      end

      # Convenience method for recording a navigation
      def record_navigate(url:, screenshot: nil)
        @recording_service&.navigate(url: url, screenshot: screenshot)
      end

      # Convenience method for recording a click
      def record_click(selector:, screenshot: nil, element_description: nil)
        @recording_service&.click(
          selector: selector,
          screenshot: screenshot,
          metadata: { element: element_description }.compact
        )
      end

      # Convenience method for recording text input
      def record_type(selector:, text:, screenshot: nil)
        @recording_service&.type(selector: selector, text: text, screenshot: screenshot)
      end

      # Record current page state for handoff
      def capture_for_handoff(url:, cookies: nil, local_storage: nil, form_values: nil)
        @recording_service&.capture_handoff_state(
          url: url,
          cookies: cookies,
          local_storage: local_storage,
          form_values: form_values
        )
      end

      # Complete the recording
      def complete!
        @recording_service&.complete!
      end

      # Fail the recording
      def fail!(error_message = nil)
        @recording_service&.fail!(error_message)
      end

      private

      def find_or_create_recording
        if @sandbox_session
          SessionRecording.recording.find_by(sandbox_session: @sandbox_session) ||
            SessionRecording.start!(sandbox_session: @sandbox_session)
        elsif @agent_run
          SessionRecording.recording.find_by(agent_run: @agent_run) ||
            SessionRecording.start!(agent_run: @agent_run)
        end
      end

      def record_action(action_type, tool_name, parameters, result, screenshot, error)
        return unless @recording_service

        metadata = {
          tool_name: tool_name,
          parameters: parameters,
          error: error
        }.compact

        case action_type
        when "navigate"
          @recording_service.navigate(
            url: parameters["url"],
            screenshot: screenshot
          )
        when "click"
          @recording_service.click(
            selector: parameters["ref"] || parameters["selector"],
            screenshot: screenshot,
            metadata: metadata.merge(
              element: parameters["element"],
              button: parameters["button"]
            ).compact
          )
        when "type"
          @recording_service.type(
            selector: parameters["ref"] || parameters["selector"],
            text: parameters["text"],
            screenshot: screenshot,
            metadata: metadata
          )
        when "form_fill"
          @recording_service.fill_form(
            fields: parameters["fields"] || [],
            screenshot: screenshot
          )
        when "key_press"
          @recording_service.key_press(
            key: parameters["key"],
            screenshot: screenshot
          )
        when "snapshot"
          # For snapshots, extract DOM if available
          dom = extract_dom(result)
          @recording_service.capture_snapshot(
            screenshot: screenshot,
            dom: dom,
            full_page: parameters["fullPage"]
          )
        when "hover"
          @recording_service.hover(
            selector: parameters["ref"] || parameters["selector"],
            screenshot: screenshot
          )
        when "select"
          @recording_service.select_option(
            selector: parameters["ref"] || parameters["selector"],
            values: parameters["values"] || [],
            screenshot: screenshot
          )
        when "file_upload"
          @recording_service.file_upload(
            paths: parameters["paths"] || [],
            screenshot: screenshot
          )
        when "dialog"
          @recording_service.dialog(
            accept: parameters["accept"],
            text: parameters["promptText"],
            screenshot: screenshot
          )
        when "evaluate"
          @recording_service.evaluate(
            function: parameters["function"],
            result: result,
            screenshot: screenshot
          )
        else
          # Generic recording for other actions
          @recording&.record_action!(
            action_type: action_type,
            selector: parameters["ref"] || parameters["selector"],
            value: parameters.to_json,
            screenshot: screenshot,
            metadata: metadata
          )
        end
      end

      def extract_screenshot(result)
        return nil unless result.is_a?(Hash) || result.respond_to?(:[])

        # Try different paths where screenshot data might be
        result["screenshot"] ||
          result[:screenshot] ||
          result.dig("data", "screenshot") ||
          result.dig(:data, :screenshot)
      end

      def extract_dom(result)
        return nil unless result.is_a?(Hash) || result.respond_to?(:[])

        result["dom"] ||
          result[:dom] ||
          result["snapshot"] ||
          result[:snapshot] ||
          result.dig("data", "dom")
      end
    end
  end
end
