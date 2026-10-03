# frozen_string_literal: true

module ActionAgent
  module Api
    # Creating this dashboard's GitHub App from a manifest (Settings ->
    # Integrations -> Create GitHub App), so a self-hoster need not register
    # one by hand. Offered only when multi_tenant is off: a multi-tenant
    # platform registers its App once, per environment, outside the
    # dashboard.
    #
    # The dashboard posts the manifest #create returns to GitHub, which
    # creates the App and returns to #callback with a code. #callback
    # converts it and shows the App's settings and credentials on a page of
    # their own, once. Nothing here stores them: the operator adds them to
    # the dashboard's configuration (see ActionAgent.github_app_id).
    class GithubAppManifestsController < BaseController
      STATE_SESSION_KEY = :action_agent_github_app_manifest_state
      # The permissions the App requests. Contents and pull requests are
      # written only by an explicit publish; the organization members read
      # is what an installation's admin check needs. No workflows,
      # administration or secrets permission.
      PERMISSIONS = { contents: "write", pull_requests: "write", metadata: "read", members: "read" }.freeze
      # GitHub's limit on an App's name.
      MAX_NAME_LENGTH = 34

      before_action :require_owner!
      before_action :require_single_tenant!
      before_action :authorize_github!

      # POST /api/github_app_manifest { organization: "acme" (optional) }
      #
      # Returns the GitHub URL to post the manifest to, with a single-use
      # state, and the manifest itself, which the dashboard submits as the
      # form field +manifest+.
      def create
        organization = params[:organization].presence
        unless organization.nil? || (organization.is_a?(String) && organization.match?(GithubClient::LOGIN))
          return render json: { error: "organization must be a GitHub organization login" }, status: :bad_request
        end

        state = SecureRandom.urlsafe_base64(32)
        session[STATE_SESSION_KEY] = { "state" => state, "user_id" => current_user_id }.compact

        render json: { url: GithubClient.new_app_url(state: state, organization: organization), manifest: manifest }
      end

      # GET /api/github_app_manifest/callback?code=...&state=...
      def callback
        # Single use: read and cleared before anything else can fail.
        issued = session.delete(STATE_SESSION_KEY)
        return redirect_to_settings(github_app: "invalid_state") unless issued_here?(issued, params[:state])
        return redirect_to_settings(github_app: "missing_code") unless params[:code].is_a?(String) && params[:code].present?

        @app = GithubClient.convert_manifest(params[:code])
        @settings_url = "#{request.script_name}/settings?tab=integrations"

        # The page carries the App's secrets: no cache keeps it, no other
        # origin's script runs on it, and its links send no referrer.
        response.headers["Cache-Control"] = "no-store"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Content-Security-Policy"] =
          "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        render template: "action_agent/github_app_manifests/created", layout: false
      rescue GithubClient::Error => e
        Rails.logger.warn("[ActionAgent] GitHub App manifest conversion failed: #{e.message}")
        redirect_to_settings(github_app: "manifest_error")
      end

      private

      def manifest
        base = "#{request.base_url}#{request.script_name}"

        {
          name: "ActiveAgent #{request.host}".first(MAX_NAME_LENGTH),
          url: base.presence || request.base_url,
          redirect_url: "#{base}/api/github_app_manifest/callback",
          callback_urls: [ "#{base}/api/github_installations/callback" ],
          request_oauth_on_install: true,
          public: false,
          default_permissions: PERMISSIONS,
          default_events: []
        }
      end

      def issued_here?(issued, given)
        issued.is_a?(Hash) && issued["state"].is_a?(String) && given.is_a?(String) &&
          ActiveSupport::SecurityUtils.secure_compare(issued["state"], given) &&
          issued["user_id"] == current_user_id
      end

      def current_user_id
        current_user.respond_to?(:id) ? current_user.id.to_s : nil
      end

      def require_single_tenant!
        return unless ActionAgent.multi_tenant?
        return redirect_to_settings(github_app: "manifest_unavailable") if action_name == "callback"

        render json: { error: "Creating a GitHub App is not available on a multi-tenant dashboard", code: "manifest_unavailable" },
          status: :not_found
      end

      def authorize_github!
        authorize_action!(:manage_github, owned(GithubInstallation).new)
      end

      # The callback is a browser navigation, so a refusal returns to
      # Settings, discarding the state.
      def permission_denied(action)
        return super unless action_name == "callback"

        session.delete(STATE_SESSION_KEY)
        redirect_to_settings(github_app: "forbidden")
      end

      def redirect_to_settings(**query)
        redirect_to "#{request.script_name}/settings?#{{ tab: 'integrations' }.merge(query).to_query}"
      end
    end
  end
end
