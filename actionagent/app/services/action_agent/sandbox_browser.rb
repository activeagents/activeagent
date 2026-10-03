# frozen_string_literal: true

module ActionAgent
  # Used to start and stop a checkout sandbox's browser, and to account for
  # it: the browser columns of its SandboxSession, the SessionRecording of
  # what it showed, and the minutes it ran.
  #
  # A sandbox runs at most one browser, which the sandbox backend starts
  # (SandboxOrchestrator#start_browser) pointed at the sandbox's app. While
  # it runs, every agent run against the sandbox reaches it as the MCP server
  # "browser:<session_id>" (SandboxSession#browser_server_entry).
  #
  # Browser statuses:
  #   starting  the backend is starting it
  #   running   its MCP endpoint answers
  #   stopped   it was stopped, or its sandbox expired
  #   failed    it did not start
  class SandboxBrowser
    class Error < StandardError; end

    STARTED = %w[starting running].freeze
    # A start that has been "starting" this long died before it finished.
    STALE_START = 10.minutes

    # Starts +sandbox+'s browser and returns the sandbox, with the browser
    # running.
    #
    # @param mode [String, Symbol] one of SandboxSession::BROWSER_MODES
    # @param capabilities [Array<String>] optional tool groups, from
    #   SandboxSession::BROWSER_CAPABILITIES
    # @param recording_url [#call, nil] given the browser's new
    #   SessionRecording, returns the absolute URL its events are posted to
    #   (the recording's events endpoint); nil records nothing
    # @param storage_state [Hash, nil] a Playwright storage state the browser
    #   starts with, such as a project's saved sign-in
    # @raise [Error] when the sandbox cannot run a browser now, a browser
    #   already runs, or the backend failed to start one
    def self.start(sandbox, mode:, capabilities: [], recording_url: nil, storage_state: nil)
      new(sandbox).start(mode.to_s, Array(capabilities).map(&:to_s).uniq, recording_url, storage_state)
    end

    # The sandbox, with a browser running: the one already running, or one
    # started headless (see .start) with +capabilities+ and +storage_state+.
    # Returns [sandbox, whether it started one].
    #
    # @raise [Error] as .start does
    def self.ensure_running!(sandbox, capabilities: [], recording_url: nil, storage_state: nil)
      sandbox.reload
      return [ sandbox, false ] if sandbox.browser_running?

      [ start(sandbox, mode: "headless", capabilities: capabilities, recording_url: recording_url, storage_state: storage_state), true ]
    end

    # A recording_url for .start that posts to the events endpoint of the
    # dashboard mounted at +mount_url+ (its absolute URL, the request's base
    # URL and script name), for a start outside a request. Nil without one.
    #
    # @return [Proc, nil]
    def self.recording_url_for(mount_url)
      return nil if mount_url.blank?

      ->(recording) { "#{mount_url.to_s.chomp('/')}/api/session_recordings/#{recording.id}/events" }
    end

    # The running browser's cookies and localStorage for the sandbox's app,
    # as a Playwright storage state, read from the sidecar's
    # GET /storage-state next to its MCP endpoint.
    #
    # @raise [Error] when no browser runs or it does not answer
    # @return [Hash]
    def self.storage_state(sandbox)
      entry = sandbox.browser_server_entry or raise Error, "The sandbox's browser is not running"

      uri = URI.join(entry[:url], "storage-state")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 30) do |http|
        http.request(Net::HTTP::Get.new(uri, entry[:headers]))
      end
      raise Error, "The browser did not hand over its sign-in (HTTP #{response.code})" unless response.is_a?(Net::HTTPSuccess)

      state = JSON.parse(response.body)["storage_state"]
      raise Error, "The browser answered without a storage state" unless state.is_a?(Hash)

      state
    rescue JSON::ParserError, SystemCallError, IOError, Timeout::Error, Net::HTTPBadResponse, URI::Error => e
      raise Error, "The browser did not hand over its sign-in: #{e.class}"
    end

    # Stops +sandbox+'s browser through its backend, then finishes it
    # (finish!). Returns the sandbox.
    #
    # @raise [Error] when the backend could not stop it
    def self.stop(sandbox)
      if STARTED.include?(sandbox.browser_status)
        orchestrator = orchestrator!
        if orchestrator.supports?(:stop_browser) && orchestrator.stop_browser(sandbox) == false
          raise Error, "The browser could not be stopped; try again"
        end
      end
      finish!(sandbox)
      sandbox
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "The browser could not be stopped: #{e.message}"
    end

    # Stops +sandbox+'s browser through its backend (stop) when one is
    # starting or running and the sandbox is not yet past its expiry. Called
    # before a sandbox is expired, so the browser's last recorded events are
    # posted while its recording still accepts them. Past the expiry the
    # recording would refuse them, and the browser has already stopped itself
    # (SandboxSession#browser_stops_at), so this does nothing. Never raises:
    # a browser it cannot stop is left to finish! and SandboxCleanupJob.
    def self.stop_before_expiry(sandbox)
      sandbox.reload
      return unless STARTED.include?(sandbox.browser_status) && sandbox.expires_at&.future?

      stop(sandbox)
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] could not stop the browser of sandbox #{sandbox.session_id} before expiring it: #{e.message}")
    end

    # The configured sandbox backend, or Error when it cannot be loaded.
    def self.orchestrator!
      SandboxOrchestrator.new
    rescue StandardError, LoadError => e
      raise Error, "The sandbox backend is unavailable: #{e.message}"
    end

    # Marks +sandbox+'s browser stopped and clears its endpoint and token, so
    # no run reaches it any more, then records the minutes it ran
    # (ActionAgent.record_usage with :browser_minutes, against
    # SandboxSession#metering_owner) and completes the sandbox's live
    # recordings. Asks nothing of the backend. Does nothing unless the
    # browser was starting or running.
    #
    # @return [Integer, nil] the minutes recorded, nil when none were
    def self.finish!(sandbox)
      minutes = nil
      finished = false
      sandbox.with_lock do
        next unless STARTED.include?(sandbox.browser_status)

        minutes = sandbox.browser_minutes if sandbox.browser_started_at
        sandbox.update!(browser_status: "stopped", browser_mcp_url: nil, browser_live_url: nil, browser_token: nil)
        finished = true
      end
      return nil unless finished

      ActionAgent.record_usage(sandbox.metering_owner, :browser_minutes, minutes) if minutes
      SessionRecording.recording.where(sandbox_session_id: sandbox.id).find_each(&:complete!)
      minutes
    end

    def initialize(sandbox)
      @sandbox = sandbox
    end

    def start(mode, capabilities, recording_url, storage_state = nil)
      validate!(mode, capabilities)
      orchestrator = self.class.orchestrator!
      unless orchestrator.supports?(:start_browser)
        raise Error, "The #{orchestrator.backend_name} sandbox backend cannot run a browser"
      end
      unless orchestrator.browser_modes.include?(mode.to_sym)
        raise Error, "The #{orchestrator.backend_name} sandbox backend cannot show a browser window; start the browser headless"
      end

      token = "aabrw_#{SecureRandom.base58(40)}"
      claim!(mode, token)
      recording = nil
      launch = nil
      begin
        recording, launch_recording = start_recording(recording_url)
        launch = { token: token, app_url: @sandbox.cloud_run_url, capabilities: capabilities, stop_at: @sandbox.browser_stops_at,
                   recording: launch_recording, storage_state: storage_state }.compact
        @sandbox.browser_launch = launch
        result = orchestrator.start_browser(@sandbox, mode: mode.to_sym)
        unless mark_running!(result, token)
          release(orchestrator)
          raise Error, "The sandbox stopped while its browser was starting"
        end
      rescue StandardError, LoadError => e
        failed!(recording, e)
        message = e.is_a?(Error) ? e.message : "The browser did not start: #{e.message}"
        raise Error, SecretScrubber.scrub(message, [ token, launch&.dig(:recording, :token) ])
      ensure
        @sandbox.browser_launch = nil
      end
      @sandbox
    end

    private

    def validate!(mode, capabilities)
      raise Error, "Only a checkout sandbox runs a browser" unless @sandbox.app_runtime?
      unless @sandbox.active? && (@sandbox.ready? || @sandbox.running?)
        raise Error, "The sandbox is #{@sandbox.status}; start its browser once it is ready"
      end
      raise Error, "The sandbox expires too soon to start a browser" unless @sandbox.browser_stops_at&.future?
      raise Error, "The sandbox has no app to open" if @sandbox.cloud_run_url.blank?
      unless SandboxSession::BROWSER_MODES.include?(mode)
        raise Error, "mode must be one of #{SandboxSession::BROWSER_MODES.join(', ')}"
      end

      unknown = capabilities - SandboxSession::BROWSER_CAPABILITIES
      raise Error, "Unknown browser capabilities: #{unknown.join(', ')}" if unknown.any?
    end

    # Takes the browser for this start, under the row lock: refused while
    # another start or browser holds it.
    def claim!(mode, token)
      @sandbox.with_lock do
        if STARTED.include?(@sandbox.browser_status) && !stale_start?
          raise Error, "The sandbox's browser is already #{@sandbox.browser_status}"
        end

        @sandbox.update!(browser_status: "starting", browser_mode: mode, browser_token: token, browser_mcp_url: nil,
          browser_live_url: nil, browser_started_at: nil)
      end
    end

    def stale_start?
      @sandbox.browser_status == "starting" && @sandbox.updated_at < STALE_START.ago
    end

    # A new recording for the browser, and what the backend needs to post to
    # it: nil for both without +recording_url+.
    def start_recording(recording_url)
      return [ nil, nil ] if recording_url.nil?

      recording = SessionRecording.start!(sandbox_session: @sandbox, source: "agent",
        name: "browser_#{Time.current.strftime('%Y%m%d_%H%M%S')}")
      limits = RecordingEvent.limits
      [ recording, {
        url: recording_url.call(recording),
        token: recording.issue_ingest_token!,
        batch_events: limits[:batch_events],
        batch_bytes: limits[:batch_bytes]
      } ]
    end

    # Records the running browser, unless the sandbox was stopped or expired
    # while it started. Returns whether it did.
    def mark_running!(result, token)
      @sandbox.with_lock do
        next false unless @sandbox.browser_status == "starting" && @sandbox.active?

        @sandbox.update!(
          browser_status: "running",
          browser_mcp_url: result[:mcp_url],
          browser_token: result[:mcp_token].presence || token,
          browser_live_url: result[:live_url],
          browser_started_at: Time.current
        )
        true
      end
    end

    def release(orchestrator)
      orchestrator.stop_browser(@sandbox)
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] could not stop the browser of sandbox #{@sandbox.session_id}: #{e.message}")
    end

    def failed!(recording, error)
      @sandbox.with_lock do
        next unless @sandbox.browser_status == "starting"

        @sandbox.update!(browser_status: "failed", browser_token: nil, browser_mcp_url: nil, browser_live_url: nil)
      end
      recording&.fail!("The browser did not start")
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] could not record a failed browser start (#{error.class}): #{e.message}")
    end
  end
end
