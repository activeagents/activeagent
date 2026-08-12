# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    module Api
      # Base class for the dashboard's JSON API — everything the React
      # dashboard reads and writes.
      #
      # Authentication is the host app's (ActiveAgent::Dashboard
      # .authentication_method), and so is ownership: `owned` scopes any
      # dashboard relation to the signed-in user or account depending on what
      # the model declared with `owned_by`, which is how a single-user
      # install, a per-user install and a multi-tenant platform all read the
      # same controllers.
      #
      # Note this is not the telemetry ingest endpoint — that authenticates
      # with a bearer token and lives in Api::TracesController.
      class BaseController < ActiveAgent::Dashboard::ApplicationController
        skip_forgery_protection

        rescue_from ActiveRecord::RecordNotFound, with: :not_found
        rescue_from ActiveRecord::RecordInvalid, with: :unprocessable_entity
        rescue_from ActionController::ParameterMissing, with: :bad_request

        private

        # Scopes +relation+ to the caller, following the model's own
        # declaration. Unowned models (a single-user install, or a model that
        # nothing owns) come back unfiltered.
        def owned(relation)
          klass = relation.respond_to?(:klass) ? relation.klass : relation

          case klass.owner_association
          when :account then relation.where(account_id: current_account&.id)
          when :user then relation.where(user_id: current_user&.id)
          else relation.all
          end
        end

        # The agents the caller can see.
        def owner_agents
          owned(ActiveAgent::Dashboard::Agent)
        end

        # Reported traces visible to the caller. Scoped to the tenant in a
        # multi-tenant install; every trace otherwise.
        def owned_traces
          ActiveAgent::Dashboard.trace_model.for_account(current_account)
        end

        # The tenant, when the host app has one.
        def current_account
          return nil unless ActiveAgent::Dashboard.current_account_method

          send(ActiveAgent::Dashboard.current_account_method)
        rescue NoMethodError
          nil
        end

        # Refuses the request when a multi-tenant install can't resolve a
        # tenant. Single-tenant installs have nothing to check.
        def require_owner!
          return unless ActiveAgent::Dashboard.multi_tenant?
          return if current_owner.present?

          render json: { error: "No account" }, status: :unauthorized
        end

        # Asks the host app whether this owner may do +kind+ (:execution or
        # :trace_ingest). Unlimited unless the app said otherwise.
        def enforce_quota!(kind)
          message = ActiveAgent::Dashboard.quota_denial(current_owner, kind)
          return if message.nil?

          render json: {
            error: "Plan limit reached",
            upgrade_required: true,
            message: message
          }, status: :payment_required
        end

        def enforce_execution_quota! = enforce_quota!(:execution)

        def record_execution_usage
          ActiveAgent::Dashboard.record_usage(current_owner, :execution)
        end

        # Execution can be turned off entirely, leaving a read-only
        # observability dashboard.
        def require_execution_enabled!
          return if ActiveAgent::Dashboard.execution_enabled?

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
end
