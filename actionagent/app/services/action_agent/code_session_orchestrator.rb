# frozen_string_literal: true

module ActionAgent
  # One interface over the backends that can run a coding agent for a
  # CodeSession, the same shape SandboxOrchestrator gives browser sandboxes.
  #
  # The engine ships two: "mock" (in-memory, runs nothing) and
  # "code_on_incus" (the coi CLI, locally or over ssh). A host app that
  # operates something else — a Firecracker pool, a Kubernetes job, a
  # hosted devbox API — registers it:
  #
  #   ActionAgent.code_session_backends = { "firecracker" => "FirecrackerCodeBackend" }
  #   ActionAgent.code_session_backend = :firecracker
  #
  # A backend answers:
  #
  #   launch(session, brief:, github_token:) => { container_id:, workspace_path:, status: }
  #   run(session, prompt:)                  => { transcript:, exit_code:, duration_ms:, input_tokens:, output_tokens: }
  #   attach_command(session)                => String or nil
  #   status(session)                        => { status:, detail: }
  #   terminate(session)                     => true/false
  #   supported_tools                        => Array<String> of CodeAgentCatalog keys
  #   features                               => Hash
  #   healthy?                               => Boolean
  #
  # Only launch and run are required; anything else missing degrades rather
  # than raising, so a minimal backend still works.
  class CodeSessionOrchestrator
    BUILT_IN_BACKENDS = {
      "mock" => "ActionAgent::MockCodeSessionBackend",
      "code_on_incus" => "ActionAgent::CodeOnIncusBackend"
    }.freeze

    class UnsupportedBackendError < StandardError; end

    class << self
      def backends
        BUILT_IN_BACKENDS.merge(ActionAgent.code_session_backends.to_h.transform_keys(&:to_s))
      end

      # The backend used when a session does not name one. An unregistered
      # name falls back to the mock with a warning rather than raising:
      # a typo in an initializer should not take the dashboard down, but it
      # must not silently look like real work either.
      def default_backend
        name = ENV["CODE_SESSION_BACKEND"].presence || ActionAgent.code_session_backend.to_s
        return name if backends.key?(name)

        if name.present? && name != "mock"
          Rails.logger.warn(
            "[ActionAgent] code session backend #{name.inspect} is not registered " \
            "(ActionAgent.code_session_backends knows #{backends.keys.inspect}); " \
            "using the in-memory mock backend, which runs nothing."
          )
        end
        "mock"
      end
    end

    def initialize(backend: nil)
      @backend_name = (backend || self.class.default_backend).to_s
      class_name = self.class.backends[@backend_name]
      raise UnsupportedBackendError, "Unknown code session backend: #{@backend_name}" if class_name.nil?

      @backend = class_name.constantize.new
    end

    attr_reader :backend_name, :backend

    def launch(session, brief: {}, github_token: nil)
      require_backend!(:launch)
      result = @backend.launch(session, brief: brief, github_token: github_token).to_h.symbolize_keys

      {
        container_id: result[:container_id] || result[:container_name] || result[:pod_name],
        workspace_path: result[:workspace_path],
        status: result[:status] || "ready"
      }
    end

    def run(session, prompt:)
      require_backend!(:run)
      result = @backend.run(session, prompt: prompt).to_h.symbolize_keys

      {
        transcript: result[:transcript].to_s,
        exit_code: result[:exit_code].to_i,
        duration_ms: result[:duration_ms],
        input_tokens: result[:input_tokens],
        output_tokens: result[:output_tokens]
      }
    end

    def attach_command(session)
      return nil unless @backend.respond_to?(:attach_command)

      @backend.attach_command(session)
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] attach command failed: #{e.message}")
      nil
    end

    def status(session)
      return { status: "unknown", detail: "backend reports no status" } unless @backend.respond_to?(:status)

      @backend.status(session)
    end

    def terminate(session)
      return true unless @backend.respond_to?(:terminate)

      @backend.terminate(session)
    end

    def supported_tools
      return CodeAgentCatalog.keys unless @backend.respond_to?(:supported_tools)

      Array(@backend.supported_tools).map(&:to_s)
    end

    def supports?(tool)
      supported_tools.include?(tool.to_s)
    end

    def features
      return {} unless @backend.respond_to?(:features)

      @backend.features
    end

    def healthy?
      return true unless @backend.respond_to?(:healthy?)

      @backend.healthy?
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] code session backend health check failed: #{e.message}")
      false
    end

    def info
      { name: @backend_name, class: @backend.class.name, healthy: healthy?, features: features }
    end

    private

    def require_backend!(verb)
      return if @backend.respond_to?(verb)

      raise UnsupportedBackendError, "#{@backend.class} does not implement ##{verb}"
    end
  end
end
