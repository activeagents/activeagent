# frozen_string_literal: true

module ActionAgent
  module Api
    # A run against a checkout sandbox the agent does not name: `sandbox_id`
    # on an evaluation run or a runner run makes that one run reach the
    # sandbox's app runtime, as if the agent listed "sandbox:<session_id>" in
    # mcp_servers, without saving it there. It is how a change being tried in
    # a checkout is evaluated before anyone edits the agent.
    #
    # The sandbox has to be the caller's (found the way CodeSessionsController
    # finds one: owned, and in the current account), a checkout, live, and
    # owned by the agent's owner as well, since the dispatcher resolves the
    # runtime among that owner's sessions only (see
    # SandboxSession.runtime_server_entry). Anything else is refused with a
    # 422 saying which. Only the key and the checkout it names are passed on
    # and recorded; the runtime's token stays on the session.
    module RunSandbox
      extend ActiveSupport::Concern

      class Refused < StandardError; end

      included do
        rescue_from Refused do |error|
          render json: { error: error.message, code: "sandbox_refused" }, status: :unprocessable_entity
        end
      end

      private

      # The caller's live checkout sandbox that +sandbox_id+ names for a run
      # of +agent+, or nil when none was asked for. Raises Refused.
      #
      # @return [SandboxSession, nil]
      def run_sandbox_for(agent, sandbox_id)
        return nil if sandbox_id.blank?
        raise Refused, "sandbox_id must be a sandbox's session id" unless sandbox_id.is_a?(String)

        scope = owned(SandboxSession)
        scope = scope.where(account_id: current_account.id) if current_account
        # Unknown and someone else's read the same: whether a session id
        # exists is not the caller's to learn.
        sandbox = scope.find_by(session_id: sandbox_id) or
          raise Refused, "No sandbox #{sandbox_id.truncate(64)} of yours was found"
        label = "Sandbox #{sandbox.session_id}"

        unless sandbox.app_runtime?
          raise Refused, "#{label} is a #{sandbox.sandbox_type} sandbox; only a checkout (app_runtime) sandbox " \
            "serves an app's tools"
        end
        # Ready (or running a task), and serving: a sandbox still booting
        # can already carry an endpoint that is not answering yet.
        if !(sandbox.ready? || sandbox.running?) || sandbox.runtime_server_entry.nil?
          state = sandbox.ready? && !sandbox.active? ? "expired" : sandbox.status
          raise Refused, "#{label} is #{state}; run against a checkout sandbox once it is ready"
        end
        unless SandboxSession.runtime_server_entry(sandbox.runtime_server_key, owner: agent.owner)
          raise Refused, "#{label} does not belong to the owner of #{agent.name}, so this agent's runs cannot reach it"
        end

        sandbox
      end
    end
  end
end
