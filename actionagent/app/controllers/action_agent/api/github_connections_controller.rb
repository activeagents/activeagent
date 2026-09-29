# frozen_string_literal: true

module ActionAgent
  module Api
    # The owner's GitHub connection (Settings -> Integrations): the OAuth
    # web flow that creates it, the repositories it makes available, and
    # disconnecting it. The access token is write-only; responses carry the
    # GitHub login and the chosen repositories, never the token.
    #
    # #connect and #callback are browser navigations rather than fetches, so
    # they answer with redirects back into the dashboard's Settings view.
    class GithubConnectionsController < BaseController
      STATE_SESSION_KEY = :action_agent_github_oauth_state

      before_action :require_owner!
      before_action :require_github_oauth!, only: [ :connect, :callback ]
      before_action :set_connection, only: [ :repositories, :update, :destroy ]

      # Later handlers win, so the subclass is registered last.
      rescue_from GithubClient::Error, with: :github_unavailable
      rescue_from GithubClient::Unauthorized, with: :github_unauthorized

      # GET /api/github_connection
      def show
        connection = owned(GithubConnection).first

        render json: {
          configured: ActionAgent.github_oauth_configured?,
          connected: connection.present?,
          connection: connection&.as_summary
        }
      end

      # GET /api/github_connection/repositories — what the token reaches,
      # each marked with whether the workspace has it selected.
      def repositories
        selected = @connection.repository_names.map(&:downcase).to_set

        render json: {
          repositories: @connection.client.repositories.map do |repo|
            repo.merge("selected" => selected.include?(repo["full_name"].downcase))
          end
        }
      end

      # PATCH /api/github_connection { repositories: ["owner/name", ...] }
      #
      # Only names GitHub lists for this token are kept: the selection is
      # what a checkout sandbox trusts, so it is never taken from the client.
      def update
        # Not params.require: an empty list (clear the selection) is valid.
        requested = params[:repositories]
        unless requested.is_a?(Array) && requested.all? { |name| name.is_a?(String) }
          return render json: { error: "repositories must be a list of owner/name strings" }, status: :bad_request
        end

        available = @connection.client.repositories.index_by { |repo| repo["full_name"].downcase }
        unknown = requested.reject { |name| available.key?(name.downcase) }
        if unknown.any?
          return render json: { error: "Not reachable with this GitHub connection: #{unknown.join(', ')}" },
            status: :unprocessable_entity
        end

        @connection.update!(repositories: requested.map { |name| available.fetch(name.downcase) }.uniq { |repo| repo["id"] })
        render json: { connected: true, connection: @connection.as_summary }
      end

      # DELETE /api/github_connection
      def destroy
        @connection.destroy!
        head :no_content
      end

      # GET /api/github_connection/connect — starts the OAuth web flow.
      def connect
        state = SecureRandom.urlsafe_base64(32)
        session[STATE_SESSION_KEY] = state

        redirect_to GithubClient.authorize_url(redirect_uri: callback_url, state: state), allow_other_host: true
      end

      # GET /api/github_connection/callback?code=...&state=...
      def callback
        # Single use: read and cleared before anything else can fail.
        expected = session.delete(STATE_SESSION_KEY)
        return redirect_to_settings(github: "denied") if params[:error].present?

        unless expected.present? && params[:state].is_a?(String) &&
            ActiveSupport::SecurityUtils.secure_compare(expected, params[:state])
          return redirect_to_settings(github: "invalid_state")
        end
        return redirect_to_settings(github: "missing_code") unless params[:code].is_a?(String) && params[:code].present?

        grant = GithubClient.exchange_code(code: params[:code], redirect_uri: callback_url)
        user = GithubClient.new(grant[:access_token]).user

        # Built through the owner scope, like a provider key, so the new
        # record carries whichever owner column this install uses.
        connection = owned(GithubConnection).first || owned(GithubConnection).new
        # A different GitHub account starts with nothing selected: the old
        # selection was checked against the other account's access.
        connection.repositories = [] if connection.persisted? && connection.github_user_id != user["id"]
        connection.update!(
          access_token: grant[:access_token],
          scopes: grant[:scope],
          github_user_id: user["id"],
          login: user["login"],
          avatar_url: user["avatar_url"]
        )

        redirect_to_settings(github: "connected")
      rescue GithubClient::Error => e
        Rails.logger.warn("[ActionAgent] GitHub OAuth callback failed: #{e.message}")
        redirect_to_settings(github: "error")
      end

      private

      def set_connection
        @connection = owned(GithubConnection).first!
      end

      def require_github_oauth!
        return if ActionAgent.github_oauth_configured?

        redirect_to_settings(github: "not_configured")
      end

      def callback_url
        "#{request.base_url}#{request.script_name}/api/github_connection/callback"
      end

      def redirect_to_settings(**query)
        redirect_to "#{request.script_name}/settings?#{{ tab: 'integrations' }.merge(query).to_query}"
      end

      def github_unauthorized
        render json: { error: "GitHub rejected the stored token. Reconnect GitHub.", reconnect_required: true },
          status: :unprocessable_entity
      end

      def github_unavailable(exception)
        render json: { error: exception.message }, status: :bad_gateway
      end
    end
  end
end
