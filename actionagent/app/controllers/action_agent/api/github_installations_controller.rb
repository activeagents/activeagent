# frozen_string_literal: true

module ActionAgent
  module Api
    # GitHub App installations (Settings -> Integrations): installing the App
    # and linking the installation, choosing the repositories checkout
    # sandboxes may use on it, and unlinking it. Unlinking leaves the App
    # installed on GitHub.
    #
    # #install and #callback are browser navigations rather than fetches, so
    # they answer with redirects back into the dashboard's Settings view,
    # reporting the outcome as ?github_app=<outcome>.
    class GithubInstallationsController < BaseController
      STATE_SESSION_KEY = :action_agent_github_app_state

      before_action :require_owner!
      before_action :require_github_app!, except: [ :index, :destroy ]
      before_action :set_installation, only: [ :repositories, :update, :destroy ]
      # The repository listing too: an installation can reach repositories a
      # member cannot see on GitHub, and the listing exists only to choose
      # them.
      before_action :authorize_github!, only: [ :install, :callback, :repositories, :update, :destroy ]

      # Later handlers win, so the subclasses are registered last.
      rescue_from GithubClient::Error, with: :github_unavailable
      rescue_from GithubClient::Unauthorized, with: :github_app_rejected
      rescue_from GithubClient::InstallationUnavailable, with: :installation_unavailable

      # GET /api/github_installations
      def index
        render json: {
          configured: ActionAgent.github_app_configured?,
          installations: owned(GithubInstallation).order(:id).map(&:as_summary)
        }
      end

      # GET /api/github_installations/:id/repositories — what the
      # installation reaches, each marked with whether the owner selected it.
      def repositories
        selected = @installation.repository_names.map(&:downcase).to_set

        render json: {
          repositories: @installation.listing_client.installation_repositories.map do |repo|
            repo.merge("selected" => selected.include?(repo["full_name"].downcase))
          end
        }
      end

      # PATCH /api/github_installations/:id { repositories: ["owner/name", ...] }
      #
      # Only names GitHub lists for the installation are kept: the selection
      # is what a checkout sandbox trusts, so it is never taken from the
      # client.
      def update
        # Not params.require: an empty list (clear the selection) is valid.
        requested = params[:repositories]
        unless requested.is_a?(Array) && requested.all? { |name| name.is_a?(String) }
          return render json: { error: "repositories must be a list of owner/name strings" }, status: :bad_request
        end

        available = @installation.listing_client.installation_repositories.index_by { |repo| repo["full_name"].downcase }
        unknown = requested.reject { |name| available.key?(name.downcase) }
        if unknown.any?
          return render json: { error: "Not reachable through this GitHub App installation: #{unknown.join(', ')}" },
            status: :unprocessable_entity
        end

        @installation.update!(repositories: requested.map { |name| available.fetch(name.downcase) }.uniq { |repo| repo["id"] })
        render json: { installation: @installation.as_summary }
      end

      # DELETE /api/github_installations/:id
      def destroy
        @installation.destroy!
        head :no_content
      end

      # GET /api/github_installations/install — sends the admin to GitHub to
      # install the App on the repositories they choose.
      def install
        redirect_to GithubClient.installation_url(state: issue_state), allow_other_host: true
      end

      # GET /api/github_installations/callback?installation_id=&setup_action=&code=&state=
      #
      # Where GitHub returns from an installation, and from the App's user
      # authorization. A code is exchanged only together with a state this
      # session issued for the signed-in user. Two returns go through the
      # App's user authorization with a fresh state first: one with no state
      # (an install started on GitHub), and one from #install that carries no
      # code (GitHub returning from a change to an installation that already
      # existed).
      def callback
        # Single use: read and cleared before anything else can fail.
        issued = session.delete(STATE_SESSION_KEY)
        return redirect_to_settings(github_app: "denied") if params[:error].present?
        # A member asked an organization owner to install the App. GitHub
        # installs nothing until the owner approves, so there is nothing to
        # link yet.
        return redirect_to_settings(github_app: "pending") if params[:setup_action] == "request"

        if params[:state].blank?
          return start_user_authorization(installation_id_param) if installation_id_param

          return redirect_to_settings(github_app: "invalid_state")
        end
        return redirect_to_settings(github_app: "invalid_state") unless issued_here?(issued, params[:state])

        installation_id = issued["installation_id"] || installation_id_param
        return redirect_to_settings(github_app: "missing_installation") unless installation_id

        unless params[:code].is_a?(String) && params[:code].present?
          # A state that already carries an installation was issued for the
          # user authorization, which has nothing left to retry.
          return redirect_to_settings(github_app: "missing_code") if issued.key?("installation_id")

          return start_user_authorization(installation_id)
        end

        redirect_to_settings(github_app: link_installation(installation_id, params[:code]))
      rescue GithubClient::Error => e
        Rails.logger.warn("[ActionAgent] GitHub App installation callback failed: #{e.message}")
        redirect_to_settings(github_app: "error")
      end

      private

      # Links +installation_id+ to the owner when the user the code belongs
      # to administers the account the App is installed on, and answers the
      # outcome. The user token is held in this method only, for the checks,
      # and is never stored or logged.
      def link_installation(installation_id, code)
        grant = GithubClient.exchange_code(
          code: code, redirect_uri: callback_url,
          client_id: ActionAgent.github_app_client_id, client_secret: ActionAgent.github_app_client_secret
        )
        github = GithubClient.new(grant[:access_token])
        github_user = github.user

        # The installation_id GitHub put in the URL is only a claim: it has
        # to be one this user can reach.
        installation = github.user_installations.find { |candidate| candidate["id"].to_i == installation_id }
        return "not_found" unless installation
        return "not_admin" unless administers?(github, github_user, installation["account"])

        record = GithubInstallation.find_by(installation_id: installation_id)
        return "taken" if record && !owned(GithubInstallation).exists?(record.id)

        record ||= owned(GithubInstallation).new(installation_id: installation_id)
        record.user_id = current_user.id if ActionAgent.user_class.present? && current_user.respond_to?(:id)
        record.assign_from_github(installation)
        record.save!
        "linked"
      # Another owner linked the same installation between the lookup and
      # the save.
      rescue ActiveRecord::RecordNotUnique
        "taken"
      rescue ActiveRecord::RecordInvalid => e
        return "taken" if e.record.errors.of_kind?(:installation_id, :taken)

        Rails.logger.warn("[ActionAgent] GitHub App installation #{installation_id} was not linked: #{e.record.errors.full_messages.to_sentence}")
        "error"
      end

      # Whether +github_user+ administers +account+: is that user account, or
      # an active admin of that organization.
      def administers?(github, github_user, account)
        account = {} unless account.is_a?(Hash)

        case account["type"]
        when "User"
          github_user["id"].present? && account["id"].to_i == github_user["id"].to_i
        when "Organization"
          membership = github.organization_membership(account["login"].to_s)
          membership.is_a?(Hash) && membership["state"] == "active" && membership["role"] == "admin"
        else
          false
        end
      end

      # A fresh single-use state bound to this session, the signed-in user and
      # the owner. +installation_id+ is carried for the user authorization of
      # an install started on GitHub, which returns without one.
      def issue_state(installation_id: nil)
        state = SecureRandom.urlsafe_base64(32)
        session[STATE_SESSION_KEY] = {
          "state" => state,
          "user_id" => current_user_id,
          "owner_id" => current_owner_id,
          "installation_id" => installation_id
        }.compact
        state
      end

      def issued_here?(issued, given)
        issued.is_a?(Hash) && issued["state"].is_a?(String) && given.is_a?(String) &&
          ActiveSupport::SecurityUtils.secure_compare(issued["state"], given) &&
          issued["user_id"] == current_user_id && issued["owner_id"] == current_owner_id
      end

      def start_user_authorization(installation_id)
        url = GithubClient.authorize_url(
          redirect_uri: callback_url, state: issue_state(installation_id: installation_id),
          client_id: ActionAgent.github_app_client_id, scope: nil
        )
        redirect_to url, allow_other_host: true
      end

      def installation_id_param
        value = params[:installation_id]
        value.to_i if value.is_a?(String) && value.match?(/\A[1-9]\d{0,18}\z/)
      end

      def current_user_id
        current_user.respond_to?(:id) ? current_user.id.to_s : nil
      end

      def current_owner_id
        current_owner.respond_to?(:id) ? current_owner.id.to_s : nil
      end

      def set_installation
        @installation = owned(GithubInstallation).find(params[:id])
      end

      # Asks about the installation acted on, or about an unsaved one when
      # #install or #callback may create it.
      def authorize_github!
        authorize_action!(:manage_github, @installation || owned(GithubInstallation).new)
      end

      # #install and #callback return a refusal to Settings like their other
      # outcomes. The callback's state is discarded with it.
      def permission_denied(action)
        return super unless navigation?

        session.delete(STATE_SESSION_KEY)
        redirect_to_settings(github_app: "forbidden")
      end

      def require_github_app!
        return if ActionAgent.github_app_configured?
        return redirect_to_settings(github_app: "not_configured") if navigation?

        render json: { error: "No GitHub App is configured on this dashboard", code: "github_app_not_configured" },
          status: :not_found
      end

      def navigation?
        action_name.in?(%w[install callback])
      end

      def callback_url
        "#{request.base_url}#{request.script_name}/api/github_installations/callback"
      end

      def redirect_to_settings(**query)
        redirect_to "#{request.script_name}/settings?#{{ tab: 'integrations' }.merge(query).to_query}"
      end

      def github_unavailable(exception)
        render json: { error: exception.message }, status: :bad_gateway
      end

      def github_app_rejected
        render json: { error: "GitHub rejected the GitHub App's credentials. Check github_app_id and github_app_private_key." },
          status: :bad_gateway
      end

      def installation_unavailable(exception)
        state = exception.reason == :suspended ? "is suspended" : "was removed"
        render json: {
          error: "This GitHub App installation #{state} on GitHub. Reinstall the GitHub App, or unlink it.",
          reinstall_required: true,
          installation: @installation&.reload&.as_summary
        }, status: :unprocessable_entity
      end
    end
  end
end
