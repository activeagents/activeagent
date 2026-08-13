# frozen_string_literal: true

module ActionAgent
  module Api
    # Base class for the dashboard's JSON API — everything the React
    # dashboard reads and writes.
    #
    # Authentication is the host app's (ActionAgent
    # .authentication_method), and so is ownership: `owned` scopes any
    # dashboard relation to the signed-in user or account depending on what
    # the model declared with `owned_by`, which is how a single-user
    # install, a per-user install and a multi-tenant platform all read the
    # same controllers.
    #
    # Note this is not the telemetry ingest endpoint — that authenticates
    # with a bearer token and lives in Api::TracesController.
    class BaseController < ActionAgent::ApplicationController
      skip_forgery_protection

      rescue_from ActiveRecord::RecordNotFound, with: :not_found
      rescue_from ActiveRecord::RecordInvalid, with: :unprocessable_entity
      rescue_from ActionController::ParameterMissing, with: :bad_request

      private

      # Scopes +relation+ to the caller, following the model's own
      # declaration. Unowned models (a single-user install, or a model that
      # nothing owns) come back unfiltered.
      # An unresolved owner scopes to nothing rather than to
      # `where(id: nil)`, which would match every unowned row and leak them
      # across tenants.
      def owned(relation)
        klass = relation.respond_to?(:klass) ? relation.klass : relation

        case klass.owner_association
        when :account then current_account ? relation.where(account_id: current_account.id) : relation.none
        when :user then current_user ? relation.where(user_id: current_user.id) : relation.none
        else relation.all
        end
      end

      # The agents the caller can see. Not simply `owned(Agent)`: a host
      # app can define reachability more broadly than ownership (an
      # account's key reaching every member's agents, say).
      def owner_agents
        ActionAgent.agents_for(current_owner)
      end

      # Reported traces visible to the caller. Scoped to the tenant in a
      # multi-tenant install; every trace otherwise.
      def owned_traces
        ActionAgent.trace_model.for_account(current_account)
      end

      # The tenant, when the host app has one. current_owner already
      # resolves it in multi-tenant mode; single-tenant installs have none.
      def current_account
        ActionAgent.multi_tenant? ? current_owner : nil
      end

      # Refuses the request when a multi-tenant install can't resolve a
      # tenant. Single-tenant installs have nothing to check.
      def require_owner!
        return unless ActionAgent.multi_tenant?
        return if current_owner.present?

        render json: { error: "No account" }, status: :unauthorized
      end

      # Asks the host app whether this owner may do +kind+ (:execution or
      # :trace_ingest). Unlimited unless the app said otherwise.
      def enforce_quota!(kind)
        denial = ActionAgent.quota_denial(current_owner, kind)
        return if denial.blank?

        body = { error: "Plan limit reached", upgrade_required: true }
        # A checker can answer with a message, or with a hash carrying
        # whatever else the host app wants the client to see (its own usage
        # numbers, an upgrade link).
        body = denial.is_a?(Hash) ? body.merge(denial) : body.merge(message: denial)

        render json: body, status: :payment_required
      end

      def enforce_execution_quota! = enforce_quota!(:execution)

      def record_execution_usage
        ActionAgent.record_usage(current_owner, :execution)
      end

      # Execution can be turned off entirely, leaving a read-only
      # observability dashboard.
      def require_execution_enabled!
        return if ActionAgent.execution_enabled?

        render json: { error: "Agent execution is disabled on this dashboard" }, status: :forbidden
      end

      def not_found
        render json: { error: "Record not found" }, status: :not_found
      end

      def unprocessable_entity(exception)
        render json: { error: exception.record.errors.full_messages }, status: :unprocessable_entity
      end

      def bad_request(exception)
        render json: { error: exception.message }, status: :bad_request
      end
    end
  end
end
