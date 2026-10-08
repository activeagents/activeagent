# frozen_string_literal: true

module ActionAgent
  # SandboxOrchestrator
  #
  # Unified interface for managing agent sandbox sessions. The engine ships
  # two backends — :mock (in-memory, runs nothing) and :local (checkouts as
  # child processes of the dashboard) — and a host registers the rest
  # (Incus, Cloud Run, Kubernetes) in ActionAgent.sandbox_backends.
  #
  # Configuration:
  #   ActionAgent.sandbox_service, or the SANDBOX_BACKEND environment
  #   variable, which wins. Default: :mock.
  #
  # Usage:
  #   orchestrator = SandboxOrchestrator.new
  #   result = orchestrator.create_sandbox(session)
  #   status = orchestrator.status(container_id)
  #   orchestrator.terminate(container_id)
  #
  class SandboxOrchestrator
    # Anything that talks to real infrastructure (Incus, Kubernetes, Cloud
    # Run) is registered by the app that operates it, so the engine carries
    # none of those SDKs:
    #
    #   ActionAgent.sandbox_backends = {
    #     "cloud_run" => "CloudRunService"
    #   }
    #
    # The engine also ships :local, which boots app_runtime checkouts as
    # child processes of the dashboard itself (see LocalSandboxBackend and
    # ActionAgent.local_sandboxes_enabled?).
    BUILT_IN_BACKENDS = {
      "mock" => "ActionAgent::MockSandboxBackend",
      "local" => "ActionAgent::LocalSandboxBackend"
    }.freeze

    # Backends disagree on what to call each verb. Candidates are tried in
    # order and the first the backend responds to wins, so a host-registered
    # class needs no adapter of its own.
    ADAPTER_METHODS = {
      create: %i[create_sandbox create_sandbox_pod create_sandbox_job],
      status: %i[status container_status pod_status job_status],
      terminate: %i[terminate terminate_pod cancel_job],
      list: %i[list_sandboxes list_sandbox_pods list_jobs],
      cleanup: %i[cleanup_expired cleanup_expired_pods cleanup_expired_jobs],
      # Claude Code sessions inside an app_runtime checkout. Optional: a
      # backend without them simply cannot run sessions (see #supports?).
      code_session: %i[run_code_session],
      cancel_code_session: %i[cancel_code_session],
      # Optional too, each documented on the orchestrator method of the same
      # name. A backend implements a verb by defining a public method with
      # that name and signature.
      changed_files: %i[changed_files],
      read_file: %i[read_file],
      start_browser: %i[start_browser],
      stop_browser: %i[stop_browser],
      resume_boot: %i[resume_boot],
      boot_status: %i[boot_status],
      boot_log: %i[boot_log],
      start_claude_login: %i[start_claude_login],
      submit_claude_login_code: %i[submit_claude_login_code],
      claude_login_status: %i[claude_login_status],
      claude_logout: %i[claude_logout],
      refresh_runtime: %i[refresh_runtime]
    }.freeze

    # What #start_browser may be asked for: a browser with no window, or one
    # a person can watch where the backend can show one.
    BROWSER_MODES = %i[headless headed].freeze

    class UnsupportedBackendError < StandardError; end
    # A host-registered backend failed a sign-in verb (see #login_call).
    class BackendError < StandardError; end

    # All backend names available in this install.
    def self.backends
      BUILT_IN_BACKENDS.merge(ActionAgent.sandbox_backends.to_h.transform_keys(&:to_s))
    end

    # The backend used when none is named: whatever the host app configured
    # as sandbox_service, falling back to the in-memory one.
    def self.default_backend
      name = ENV["SANDBOX_BACKEND"].presence || ActionAgent.sandbox_service.to_s
      return name if backends.key?(name)

      # Substituting the mock silently made a misconfigured operator's
      # sandbox "runs" succeed against nothing real.
      if name.present? && name != "mock"
        Rails.logger.warn(
          "[ActionAgent] sandbox backend #{name.inspect} is not registered " \
          "(ActionAgent.sandbox_backends knows #{backends.keys.inspect}); " \
          "using the in-memory mock backend, which runs nothing."
        )
      end
      "mock"
    end

    def initialize(backend: nil)
      @backend_name = (backend || self.class.default_backend).to_s
      class_name = self.class.backends[@backend_name]
      raise UnsupportedBackendError, "Unknown backend: #{@backend_name}" if class_name.nil?

      @backend = class_name.constantize.new
    end

    attr_reader :backend_name

    # Login adapters return only flow state / the CLI authorize URL. No
    # credential, terminal output or echoed code may cross this boundary.
    # Whatever a host-registered backend raises comes out as BackendError,
    # which callers rescue along with the local backend's own errors.
    def start_claude_login(sandbox) = login_call { @backend.public_send(adapter_method(:start_claude_login), sandbox) }
    def submit_claude_login_code(sandbox, code) = login_call { @backend.public_send(adapter_method(:submit_claude_login_code), sandbox, code) }
    def claude_login_status(sandbox) = login_call { @backend.public_send(adapter_method(:claude_login_status), sandbox) }
    def claude_logout(sandbox) = login_call { @backend.public_send(adapter_method(:claude_logout), sandbox) }
    def refresh_runtime(sandbox) = @backend.public_send(adapter_method(:refresh_runtime), sandbox)

    # Create a new sandbox for the given session
    #
    # @param sandbox_session [SandboxSession] The session to create a sandbox for
    # @param instance_tier [String, Symbol, SandboxInstanceTier] Optional instance tier
    # @param boot_config [SandboxBootSpec, Hash, nil] how to boot the checkout
    #   instead of its own .activeagents/sandbox.yml, handed to the backend as
    #   SandboxBootSpec#to_h. A backend whose create method takes no
    #   boot_config: keyword boots as it always has; one that must apply
    #   (apply "always") is refused there instead.
    # @return [Hash] Sandbox details including ID/name and URL
    # @raise [UnsupportedBackendError] for a spec that must apply and a backend
    #   that cannot take one
    # @raise [SandboxBootSpec::Invalid] for a malformed spec
    def create_sandbox(sandbox_session, instance_tier: nil, boot_config: nil)
      # Resolve tier
      tier = resolve_tier(instance_tier)
      spec = SandboxBootSpec.wrap(boot_config)

      method = adapter_method(:create)
      options = {}
      options[:instance_tier] = tier if accepts_instance_tier?(method)
      if spec && accepts_keyword?(method, :boot_config)
        options[:boot_config] = spec.to_h
      elsif spec && !spec.without_engine_only?
        raise UnsupportedBackendError, "The #{backend_name} sandbox backend cannot boot a checkout from a boot spec"
      end
      result = @backend.public_send(method, sandbox_session, **options)

      normalize_created(result, tier)
    end

    # List available instance tiers
    #
    # @param category [String, nil] Optional category filter (free, pro, enterprise)
    # @return [Array<SandboxInstanceTier>] Available tiers
    def available_tiers(category: nil)
      tiers = SandboxInstanceTier.available
      tiers = tiers.select { |t| t.category == category.to_s } if category
      tiers
    end

    # Get a specific instance tier
    #
    # @param tier_id [String, Symbol] Tier ID
    # @return [SandboxInstanceTier]
    def get_tier(tier_id)
      SandboxInstanceTier.find(tier_id)
    end

    # Get the status of a sandbox
    #
    # @param sandbox_id [String] The sandbox ID (container name, pod name, etc.)
    # @return [Hash] Sandbox status
    def status(sandbox_id)
      @backend.public_send(adapter_method(:status), sandbox_id)
    end

    # Terminate a sandbox
    #
    # @param sandbox_id [String] The sandbox ID to terminate
    # @return [Boolean] true if terminated
    def terminate(sandbox_id)
      @backend.public_send(adapter_method(:terminate), sandbox_id)
    end

    # List all active sandboxes
    #
    # @return [Array<Hash>] List of sandbox statuses
    def list_sandboxes
      @backend.public_send(adapter_method(:list))
    end

    # Cleanup expired sandboxes
    #
    # @return [Integer] Number of sandboxes cleaned up
    def cleanup_expired
      @backend.public_send(adapter_method(:cleanup))
    end

    # The handle the backend would give +sandbox_session+'s sandbox, for a
    # backend that derives it from the session (nil otherwise).
    def handle_for(sandbox_session)
      @backend.respond_to?(:handle_for) ? @backend.handle_for(sandbox_session) : nil
    end

    # Whether the backend can name a session's sandbox without a recorded
    # handle (see #handle_for).
    def derives_handles?
      @backend.respond_to?(:handle_for)
    end

    # Whether the backend runs sandboxes as processes of the dashboard, on
    # its own machine and as its own user (LocalSandboxBackend): the only
    # place ActionAgent.claude_code_auth = :local_login can work.
    def local?
      @backend.is_a?(LocalSandboxBackend)
    end

    # Whether the backend implements +verb+ (an ADAPTER_METHODS key).
    def supports?(verb)
      ADAPTER_METHODS.fetch(verb).any? { |m| @backend.respond_to?(m) }
    end

    # Whether the backend's create method takes a boot spec (see
    # #create_sandbox's boot_config:).
    def accepts_boot_config?
      accepts_keyword?(adapter_method(:create), :boot_config)
    end

    # Whether the backend can list a checkout's changes and read each file
    # now and in the commit the checkout was cloned at: #changed_files, and
    # #read_file with +base+.
    def reads_checkouts?
      supports?(:changed_files) && reads_checkout_commit?
    end

    # Whether the backend's read_file takes +base:+. A backend written before
    # +base:+ existed defines read_file(session, path) and cannot be asked
    # for the commit cloned at.
    def reads_checkout_commit?
      return false unless supports?(:read_file)

      @backend.method(adapter_method(:read_file)).parameters.any? do |type, name|
        type == :keyrest || type == :rest || (type.in?(%i[key keyreq]) && name == :base)
      end
    end

    # Existing backends predate runner selection and support Claude only.
    # A backend must explicitly advertise Codex before accepting its keys.
    def supports_code_runner?(runner)
      return false unless supports?(:code_session)

      runners = @backend.respond_to?(:code_runners) ? @backend.code_runners : [ "claude_code" ]
      Array(runners).include?(runner)
    end

    # Runs a Claude Code session in +sandbox_session+'s checkout, yielding
    # each stream-json event (a Hash) as it arrives. Returns the backend's
    # outcome: { exit_status:, diff: }.
    def run_code_session(sandbox_session, code_session, &on_event)
      # Checked when a session is requested too; this covers one queued
      # before the configuration changed.
      runner = code_session.try(:runner) || "claude_code"
      unless supports_code_runner?(runner)
        raise UnsupportedBackendError, "The #{backend_name} sandbox backend cannot run #{runner} sessions"
      end
      refusal = ClaudeCodeAuth.backend_refusal(self) unless runner == "codex"
      raise UnsupportedBackendError, refusal if refusal
      if runner == "claude_code" && code_session.try(:credential_mode) == "sandbox_login"
        unless sandbox_session.claude_login_user_id.present? && sandbox_session.claude_login_user_id == code_session.user_id &&
            claude_login_status(sandbox_session).slice(:logged_in, :auth_method) == { logged_in: true, auth_method: "claude.ai" }
          raise UnsupportedBackendError, "This user's Claude subscription is no longer signed in to this sandbox"
        end
      end

      @backend.public_send(adapter_method(:code_session), sandbox_session, code_session, &on_event)
    end

    # Stops a running Claude Code session.
    def cancel_code_session(sandbox_session, code_session)
      @backend.public_send(adapter_method(:cancel_code_session), sandbox_session, code_session)
    end

    # The files +sandbox_session+'s checkout has changed since it was cloned,
    # read without running anything the checkout controls (no git hooks,
    # filters or configuration from the checkout).
    #
    # @return [Hash] { base_commit:, files: }
    #   base_commit: the commit the checkout was cloned at
    #   files: one Hash per changed path, each
    #     path:   relative to the checkout root
    #     status: "added", "modified" or "deleted"
    #     mode:   "100644", "100755", "120000" (a symlink) or "160000" (a
    #             submodule, or a nested repository); nil when deleted
    #     base_mode: the mode in the commit cloned at, where the backend
    #             knows it (optional); nil when added
    #     size:   the bytes in the working tree, where the backend knows them
    #             (optional); nil when deleted
    #   Files the repository ignores are not listed.
    # @raise [UnsupportedBackendError] when the backend does not implement it
    def changed_files(sandbox_session)
      @backend.public_send(adapter_method(:changed_files), sandbox_session)
    end

    # The current content of +path+ in +sandbox_session+'s checkout, or with
    # +base+ its content in the commit the checkout was cloned at. A symlink
    # is read as its target path, never followed.
    #
    # A backend implements this as read_file(sandbox_session, path, base:),
    # and is passed +base+ only when it is true.
    #
    # @param path [String] relative to the checkout root
    # @return [String, nil] the bytes, binary-encoded; nil when nothing is
    #   there
    # @raise [ArgumentError] when +path+ is absolute or climbs out of the
    #   checkout, before the backend is asked
    # @raise [UnsupportedBackendError] when the backend does not implement
    #   it, or is asked for +base+ and its read_file takes no +base:+ (see
    #   #reads_checkout_commit?)
    def read_file(sandbox_session, path, base: false)
      unless checkout_relative?(path)
        raise ArgumentError, "#{path.inspect} is not a path inside the checkout"
      end

      method = adapter_method(:read_file)
      if base
        unless reads_checkout_commit?
          raise UnsupportedBackendError, "The #{backend_name} sandbox backend's read_file takes no base:, " \
            "so it cannot read the commit a checkout was cloned at"
        end

        @backend.public_send(method, sandbox_session, path, base: true)
      else
        @backend.public_send(method, sandbox_session, path)
      end
    end

    # Starts a browser for +sandbox_session+, one per sandbox, and returns how
    # an agent reaches it over MCP. The backend reads the rest of what it
    # needs from sandbox_session.browser_launch (see SandboxSession): the
    # token the browser's MCP endpoint is to expect, the app it may open,
    # optional tool groups, when to stop, and where to post its recording.
    #
    # @param mode [Symbol] one of BROWSER_MODES
    # @return [Hash] at least { mcp_url:, mcp_token: }: where the browser's
    #   MCP server answers, and the bearer token it expects (nil for none);
    #   optionally live_url:, where a person can watch it
    # @raise [ArgumentError] for a mode outside BROWSER_MODES
    # @raise [UnsupportedBackendError] when the backend does not implement it,
    #   or cannot run a browser in +mode+ (see #browser_modes)
    def start_browser(sandbox_session, mode: :headless)
      raise ArgumentError, "Unknown browser mode #{mode.inspect}" unless BROWSER_MODES.include?(mode)

      method = adapter_method(:start_browser)
      unless browser_modes.include?(mode)
        raise UnsupportedBackendError, "The #{backend_name} sandbox backend cannot show a browser window; start the browser headless"
      end

      @backend.public_send(method, sandbox_session, mode: mode)
    end

    # The BROWSER_MODES the backend can start a browser in: what its own
    # #browser_modes answers, or every mode for a backend that does not say.
    # Empty when it cannot start a browser at all.
    #
    # @return [Array<Symbol>]
    def browser_modes
      return [] unless supports?(:start_browser)
      return BROWSER_MODES.dup unless @backend.respond_to?(:browser_modes)

      BROWSER_MODES & Array(@backend.browser_modes).map(&:to_sym)
    end

    # Stops +sandbox_session+'s browser. True, also when none was running.
    #
    # @raise [UnsupportedBackendError] when the backend does not implement it
    def stop_browser(sandbox_session)
      @backend.public_send(adapter_method(:stop_browser), sandbox_session)
    end

    # Continues a boot of +sandbox_session+ that failed and kept its
    # workspace, re-running from the step named +from+ (nil for the step that
    # failed) with the session's current settings.
    #
    # @param boot_config [SandboxBootSpec, Hash, nil] the spec to continue
    #   with, for updated env or secrets; nil for the one the boot started
    #   with. Passed only to a backend whose method takes the keyword.
    # @return [Hash] what #create_sandbox returns
    # @raise [UnsupportedBackendError] when the backend does not implement it
    def resume_boot(sandbox_session, from:, boot_config: nil)
      method = adapter_method(:resume_boot)
      spec = SandboxBootSpec.wrap(boot_config)
      options = { from: from }
      options[:boot_config] = spec.to_h if spec && accepts_keyword?(method, :boot_config)
      normalize_created(@backend.public_send(method, sandbox_session, **options), nil)
    end

    # How +sandbox_session+'s boot went, step by step, while the backend
    # still holds it.
    #
    # @return [Hash, nil] nil when the backend holds nothing for the session;
    #   otherwise
    #     mode:        "config" (the checkout's sandbox.yml) or "spec"
    #     kind:        the spec's kind, "bootstrap" or "custom"
    #     failed_step: the name of the step that failed, or nil
    #     kept:        whether a failed boot's workspace was kept for
    #                  #resume_boot
    #     resumable_steps: optional, the step names #resume_boot accepts as
    #                  `from`
    #     steps:       [{ name:, status:, started_at:, finished_at:,
    #                  duration_ms:, detail: }], status one of "pending",
    #                  "running", "succeeded", "failed" or "skipped"
    # @raise [UnsupportedBackendError] when the backend does not implement it
    def boot_status(sandbox_session)
      @backend.public_send(adapter_method(:boot_status), sandbox_session)
    end

    # One page of a boot step's log, scrubbed of the session's secrets and
    # of +secrets+. Pages end at a line break where they can, so a value is
    # never split between two of them.
    #
    # @param step [String] a step name #boot_status lists
    # @param offset [Integer] the byte offset to read from
    # @param limit [Integer] the most bytes to read
    # @return [Hash, nil] { step:, offset:, next_offset:, size:, eof:, text: },
    #   or nil when the step has no log
    # @raise [UnsupportedBackendError] when the backend does not implement it
    def boot_log(sandbox_session, step:, offset: 0, limit: nil, secrets: [])
      options = { step: step, offset: offset, secrets: secrets }
      options[:limit] = limit if limit
      @backend.public_send(adapter_method(:boot_log), sandbox_session, **options)
    end

    # Check if the backend is healthy
    #
    # @return [Boolean] true if backend is reachable
    def healthy?
      # A backend that can list is reachable; one that cannot is assumed
      # healthy because there is nothing to probe.
      list_sandboxes if ADAPTER_METHODS[:list].any? { |m| @backend.respond_to?(m) }
      true
    rescue => e
      Rails.logger.error("Sandbox backend health check failed: #{e.message}")
      false
    end

    # Get backend-specific configuration info
    #
    # @return [Hash] Backend configuration
    def backend_info
      {
        name: @backend_name,
        class: @backend.class.name,
        healthy: healthy?,
        features: backend_features
      }
    end

    private

    # Runs a sign-in verb, turning a host-registered backend's own errors
    # into BackendError. The message is kept for the log; the sign-in
    # endpoints answer with a fixed one.
    def login_call
      yield
    rescue UnsupportedBackendError, LocalSandboxBackend::Error
      raise
    rescue StandardError => e
      raise BackendError, e.message
    end

    # The backend's method for +verb+, or a clear error naming what it
    # would have to implement.
    def adapter_method(verb)
      ADAPTER_METHODS.fetch(verb).find { |m| @backend.respond_to?(m) } ||
        raise(UnsupportedBackendError,
          "#{@backend.class} implements none of #{ADAPTER_METHODS.fetch(verb).join(', ')}")
    end

    # The backend's create result in one shape whichever backend produced it.
    def normalize_created(result, tier)
      {
        sandbox_id: result[:container_name] || result[:pod_name] || result[:job_name],
        url: result[:url],
        ip: result[:container_ip] || result[:pod_ip],
        backend: @backend_name,
        instance_tier: result[:instance_tier] || tier&.id,
        resources: result[:resources],
        hourly_cost: result[:hourly_cost] || tier&.hourly_cost&.to_f,
        created_at: result[:created_at] || Time.current,
        # An app_runtime sandbox's backend clones sandbox_session.checkout_spec,
        # boots the app, and reports where its MCP facade answers (and the
        # bearer token it expects) so agents can use the checkout's tools.
        mcp_url: result[:mcp_url],
        mcp_token: result[:mcp_token],
        # The models its manifest lists (SandboxManifest.app_models), when the
        # backend reports them.
        app_models: result[:app_models]
      }
    end

    # Whether +path+ names something inside a checkout: relative, and never
    # climbing out through "..".
    def checkout_relative?(path)
      return false unless path.is_a?(String) && path.present? && !path.include?("\0")

      pathname = Pathname.new(path)
      pathname.relative? && pathname.each_filename.none?("..")
    end

    def accepts_instance_tier?(method)
      @backend.method(method).parameters.any? { |_type, name| name == :instance_tier }
    end

    def accepts_keyword?(method, keyword)
      @backend.method(method).parameters.any? { |type, name| name == keyword && %i[key keyreq].include?(type) }
    end

    def resolve_tier(tier_param)
      return nil unless tier_param

      if tier_param.is_a?(SandboxInstanceTier)
        tier_param
      else
        SandboxInstanceTier.find(tier_param)
      end
    rescue ArgumentError
      Rails.logger.warn("Unknown instance tier: #{tier_param}, using default")
      SandboxInstanceTier.default_tier
    end

    def backend_features
      # A host-registered backend can describe itself; otherwise fall back
      # to what the engine knows about the backends it has seen.
      return @backend.features if @backend.respond_to?(:features)

      case @backend_name
      when "incus"
        {
          cloud_agnostic: true,
          isolation: "namespaces + apparmor",
          networking: "bridge",
          persistent_storage: true,
          live_migration: true,
          self_hosted: true
        }
      when "kubernetes"
        {
          cloud_agnostic: true,
          isolation: "pods + gvisor",
          networking: "cni + network_policies",
          persistent_storage: true,
          live_migration: false,
          self_hosted: true
        }
      when "cloud_run"
        {
          cloud_agnostic: false,
          isolation: "gvisor",
          networking: "vpc_connector",
          persistent_storage: false,
          live_migration: false,
          self_hosted: false
        }
      when "mock"
        {
          cloud_agnostic: true,
          isolation: "none",
          networking: "mock",
          persistent_storage: false,
          live_migration: false,
          self_hosted: true
        }
      end
    end
  end
end
