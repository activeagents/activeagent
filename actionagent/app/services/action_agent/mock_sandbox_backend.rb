# frozen_string_literal: true

module ActionAgent
  # In-memory sandbox backend. Ships with the engine so the sandbox surface
  # is exercisable in development and tests without any container runtime;
  # backends that talk to real infrastructure are registered by the host app
  # (see ActionAgent.sandbox_backends).
  class MockSandboxBackend
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
  end
end
