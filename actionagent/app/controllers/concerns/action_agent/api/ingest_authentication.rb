# frozen_string_literal: true

module ActionAgent
  module Api
    # Bearer-token authentication for the endpoints other applications post
    # to: trace ingest (Api::TracesController) and published evaluation
    # reports (Api::EvaluationReportsController). Neither is a dashboard
    # controller, so neither sees the host's session or controller concerns.
    #
    # A multi-tenant install authenticates the tenant's key and sets
    # `@account` to the tenant it names. A single-tenant install requires
    # ActionAgent.ingest_api_key when one is set and leaves `@account` nil.
    module IngestAuthentication
      extend ActiveSupport::Concern

      included do
        before_action :authenticate_api_key!, if: -> { ActionAgent.multi_tenant? }
        before_action :authenticate_ingest_key!, unless: -> { ActionAgent.multi_tenant? }
      end

      private

      # Finds the tenant whose `telemetry_api_key` is the bearer token.
      # Only used in multi-tenant mode.
      def authenticate_api_key!
        token = extract_bearer_token

        if token.blank?
          render json: { error: "Missing Authorization header" }, status: :unauthorized
          return
        end

        account_class = ActionAgent.account_class.constantize
        @account = account_class.find_by(telemetry_api_key: token)

        if @account.nil?
          render json: { error: "Invalid API key" }, status: :unauthorized
          return
        end

        record_ingest_request
      end

      # Called once the tenant has authenticated. Counts nothing here: trace
      # ingest counts the request through the tenant's
      # increment_telemetry_usage!, and the report collector records a stored
      # report through ActionAgent.usage_recorder instead.
      def record_ingest_request; end

      # Requires the configured single-tenant ingest key when one is set.
      # The telemetry reporter, ruby_llm_telemetry and
      # ActiveAgent::Evals::Publisher all send their api_key as a Bearer
      # header, so remote apps work unchanged.
      def authenticate_ingest_key!
        expected = ActionAgent.ingest_api_key
        return if expected.blank?

        token = extract_bearer_token
        return if token.present? && ActiveSupport::SecurityUtils.secure_compare(token, expected)

        render json: { error: "Invalid API key" }, status: :unauthorized
      end

      # Asks the host app's quota checker whether the tenant may do +kind+,
      # and renders 429 with +error+ when it may not. The counterpart to
      # Api::BaseController#enforce_quota!, which answers 402: a client that
      # is over its ingest allowance should back off, not upgrade mid-flush.
      # Same body shape, so a checker's message or Hash payload reads the
      # same on both.
      def enforce_ingest_quota_for!(kind, error)
        denial = ActionAgent.quota_denial(@account, kind)
        return if denial.blank?

        render json: quota_denial_body(denial, error), status: :too_many_requests
      end

      # The 429 body for a quota checker's +denial+: its Hash merged in, or
      # its String as the message.
      def quota_denial_body(denial, error)
        body = { error: error }
        denial.is_a?(Hash) ? body.merge(denial) : body.merge(message: denial)
      end

      # Extracts Bearer token from Authorization header.
      def extract_bearer_token
        auth_header = request.headers["Authorization"]
        return nil if auth_header.blank?

        match = auth_header.match(/^Bearer\s+(.+)$/i)
        match[1] if match
      end
    end
  end
end
