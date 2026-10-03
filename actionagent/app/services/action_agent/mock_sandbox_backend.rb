# frozen_string_literal: true

module ActionAgent
  # In-memory sandbox backend. Ships with the engine so the sandbox surface
  # is exercisable in development and tests without any container runtime;
  # backends that talk to real infrastructure are registered by the host app
  # (see ActionAgent.sandbox_backends).
  class MockSandboxBackend
    # What #changed_files and #read_file report for a session, by session id,
    # as .stage_checkout recorded it. Nothing here runs a checkout, so a
    # session nobody staged has no changes.
    @checkouts = {}
    @checkouts_lock = Mutex.new

    class << self
      # Records the checkout +session_id+ reads as: the commit it was cloned
      # at, that commit's files (+base+) and the working tree's (+working+).
      # Each maps a path to its content, or to { content:, mode: } for a mode
      # other than "100644" (a symlink's content is its target path).
      def stage_checkout(session_id, base_commit:, base: {}, working: {})
        checkout = { base_commit: base_commit, base: normalize_files(base), working: normalize_files(working) }
        @checkouts_lock.synchronize { @checkouts[session_id.to_s] = checkout }
      end

      def staged_checkout(session_id)
        @checkouts_lock.synchronize { @checkouts[session_id.to_s] }
      end

      def reset_checkouts!
        @checkouts_lock.synchronize { @checkouts.clear }
      end

      private

      def normalize_files(files)
        files.to_h do |path, entry|
          entry = { content: entry } unless entry.is_a?(Hash)
          [ path.to_s, { content: entry.fetch(:content).to_s.b, mode: entry[:mode] || "100644" } ]
        end
      end
    end

    def initialize
      @sandboxes = {}
    end

    def create_sandbox(session, instance_tier: nil)
      tier = instance_tier || SandboxInstanceTier.free_tier
      name = "mock-sandbox-#{SecureRandom.hex(4)}"

      @sandboxes[name] = {
        container_name: name,
        container_ip: "127.0.0.1",
        url: "http://127.0.0.1:8080",
        session_id: session.session_id,
        status: "running",
        instance_tier: tier.id,
        resources: {
          cpu_cores: tier.cpu_cores,
          memory_gb: tier.memory_gb,
          gpu: tier.gpu
        },
        hourly_cost: tier.hourly_cost.to_f,
        created_at: Time.current
      }

      # A checkout sandbox: record what would be cloned (never the token) and
      # which credentials would be passed in, and
      # report the runtime's MCP endpoint the way a real backend does. Nothing
      # answers there — this backend runs nothing.
      if (checkout = session.try(:checkout_spec))
        @sandboxes[name][:checkout] = checkout.except(:token)
        # Which variables would be set, never their values.
        @sandboxes[name][:environment_keys] = session.runtime_environment.keys
        @sandboxes[name][:mcp_url] = "http://127.0.0.1:8080/activeagents/mcp"
      end

      @sandboxes[name]
    end

    def status(sandbox_id)
      @sandboxes[sandbox_id] || { status: "not_found" }
    end

    def terminate(sandbox_id)
      @sandboxes.delete(sandbox_id)
      true
    end

    def list_sandboxes
      @sandboxes.values
    end

    def cleanup_expired
      0
    end

    # A Claude Code session that runs nothing, reported the way a real one
    # streams it (stream-json: init, the assistant's text, the result), so
    # the dashboard's session flow can be exercised end to end without the
    # CLI or a checkout.
    def run_code_session(_sandbox_session, _code_session, &on_event)
      note = "The mock sandbox backend runs nothing: no Claude Code session ran and nothing in the checkout changed."

      [
        { "type" => "system", "subtype" => "init", "model" => "mock" },
        {
          "type" => "assistant",
          "message" => { "role" => "assistant", "content" => [ { "type" => "text", "text" => note } ] }
        },
        {
          "type" => "result", "subtype" => "success", "is_error" => false, "result" => note,
          "num_turns" => 1, "duration_ms" => 0, "total_cost_usd" => 0
        }
      ].each { |event| on_event&.call(event) }

      { exit_status: 0, diff: "", stderr_tail: "" }
    end

    # Nothing runs, so there is nothing to stop.
    def cancel_code_session(_sandbox_session, _code_session)
      true
    end

    # The staged checkout's changes (see .stage_checkout), in the shape
    # SandboxOrchestrator#changed_files describes.
    def changed_files(session)
      checkout = self.class.staged_checkout(session.session_id)
      return { base_commit: nil, files: [] } if checkout.nil?

      base = checkout[:base]
      working = checkout[:working]
      files = (base.keys | working.keys).sort.filter_map do |path|
        before = base[path]
        after = working[path]
        next if before == after

        if after.nil?
          { path: path, status: "deleted", mode: nil, base_mode: before[:mode], size: nil }
        else
          { path: path, status: before ? "modified" : "added", mode: after[:mode], base_mode: before&.dig(:mode), size: after[:content].bytesize }
        end
      end

      { base_commit: checkout[:base_commit], files: files }
    end

    def read_file(session, path, base: false)
      checkout = self.class.staged_checkout(session.session_id)
      checkout&.dig(base ? :base : :working, path, :content)&.dup
    end
  end
end
