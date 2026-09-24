# frozen_string_literal: true

module ActionAgent
  # The few GitHub calls the dashboard makes: the OAuth code exchange, the
  # authenticated user, and the repositories that user can reach. Plain
  # Net::HTTP, like the provider model lookups, so the engine carries no
  # GitHub SDK.
  class GithubClient
    API = "https://api.github.com"
    TOKEN_URL = "https://github.com/login/oauth/access_token"
    AUTHORIZE_URL = "https://github.com/login/oauth/authorize"
    TIMEOUT_SECONDS = 8
    # 100 per page is GitHub's maximum; five pages bounds a picker at 500.
    PER_PAGE = 100
    MAX_PAGES = 5

    class Error < StandardError; end
    # The token was revoked or expired: the owner has to connect again.
    class Unauthorized < Error; end

    def self.authorize_url(redirect_uri:, state:)
      query = {
        client_id: ActionAgent.github_client_id,
        redirect_uri: redirect_uri,
        scope: ActionAgent.github_oauth_scopes,
        state: state,
        allow_signup: "false"
      }.to_query

      "#{AUTHORIZE_URL}?#{query}"
    end

    # Trades an OAuth code for { access_token:, scope: }.
    def self.exchange_code(code:, redirect_uri:)
      uri = URI.parse(TOKEN_URL)
      request = Net::HTTP::Post.new(uri, "Accept" => "application/json")
      request.set_form_data(
        client_id: ActionAgent.github_client_id,
        client_secret: ActionAgent.github_client_secret,
        code: code,
        redirect_uri: redirect_uri
      )
      data = perform(uri, request)
      raise Error, data["error_description"].presence || data["error"] if data["error"].present?
      raise Error, "GitHub returned no access token" if data["access_token"].blank?

      { access_token: data["access_token"], scope: data["scope"].to_s }
    end

    def self.perform(uri, request)
      response = Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: true, open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS
      ) { |http| http.request(request) }

      raise Unauthorized, "GitHub rejected the token" if response.code.to_i == 401
      raise Error, "GitHub answered #{response.code}" unless response.code.to_i.between?(200, 299)

      JSON.parse(response.body.presence || "{}")
    rescue JSON::ParserError
      raise Error, "GitHub answered with something other than JSON"
    rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
      raise Error, "GitHub is unreachable (#{e.class.name})"
    end

    def initialize(access_token)
      @access_token = access_token
    end

    def user
      get("/user")
    end

    # Every repository the token reaches (owned, collaborated on, or through
    # an organization), most recently pushed first, reduced to the fields the
    # dashboard stores.
    def repositories
      (1..MAX_PAGES).each_with_object([]) do |page, all|
        batch = get("/user/repos", per_page: PER_PAGE, page: page, sort: "pushed",
          affiliation: "owner,collaborator,organization_member")
        all.concat(Array(batch).map { |repo| self.class.slice_repository(repo) })
        break all if Array(batch).size < PER_PAGE
      end
    end

    def self.slice_repository(repo)
      {
        "id" => repo["id"],
        "full_name" => repo["full_name"],
        "private" => repo["private"] == true,
        "default_branch" => repo["default_branch"].presence || "main",
        "description" => repo["description"],
        "html_url" => repo["html_url"],
        "pushed_at" => repo["pushed_at"]
      }
    end

    private

    def get(path, params = {})
      uri = URI.parse("#{API}#{path}")
      uri.query = params.to_query if params.any?
      request = Net::HTTP::Get.new(uri,
        "Accept" => "application/vnd.github+json",
        "Authorization" => "Bearer #{@access_token}",
        "X-GitHub-Api-Version" => "2022-11-28",
        "User-Agent" => "activeagent-dashboard")
      self.class.perform(uri, request)
    end
  end
end
