# frozen_string_literal: true

module ActionAgent
  # In-memory code session backend. Ships with the engine so the Code
  # Sessions view, the brief and the jobs are exercisable in development and
  # in tests without an Incus host or a coding agent subscription — it runs
  # nothing and says so in its transcript.
  #
  # It also records what it was handed, which is how the test suite asserts
  # that a GitHub token reaches the backend and never the database.
  class MockCodeSessionBackend
    class << self
      def launches = @launches ||= []
      def runs = @runs ||= []
      def terminations = @terminations ||= []

      def reset!
        @launches = []
        @runs = []
        @terminations = []
      end
    end

    def launch(session, brief: {}, github_token: nil)
      self.class.launches << {
        session_id: session.session_id,
        tool: session.tool,
        repository: session.repository,
        branch: session.branch,
        network_mode: session.network_mode,
        github_access: session.github_access,
        github_token: github_token,
        brief_needs: Array(brief["needs"] || brief[:needs]).size
      }

      {
        container_id: "mock-code-#{SecureRandom.hex(4)}",
        workspace_path: "/workspace",
        status: "ready"
      }
    end

    def run(session, prompt:)
      self.class.runs << { session_id: session.session_id, prompt: prompt }

      where = session.repository.presence || "scratch workspace"
      first_line = prompt.to_s.lines.first.to_s.strip
      first_line = "#{first_line[0, 117]}..." if first_line.length > 120

      {
        transcript: "[mock] #{session.tool_name} in #{where}: #{first_line}",
        exit_code: 0,
        duration_ms: 1,
        input_tokens: nil,
        output_tokens: nil
      }
    end

    def attach_command(_session)
      nil
    end

    def status(session)
      { status: session.active? ? "running" : "stopped", detail: "in-memory backend" }
    end

    def terminate(session)
      self.class.terminations << session.session_id
      true
    end

    def supported_tools
      CodeAgentCatalog.keys
    end

    def features
      {
        isolation: "none",
        network: "mock",
        persistent: false,
        threat_monitoring: false,
        self_hosted: true
      }
    end

    def healthy?
      true
    end
  end
end
