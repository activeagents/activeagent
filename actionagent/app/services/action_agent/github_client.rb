# frozen_string_literal: true

require "openssl"
require "base64"

module ActionAgent
  # The GitHub calls the dashboard makes. Plain Net::HTTP and OpenSSL, like
  # the provider model lookups, so the engine carries no GitHub SDK and no
  # JWT library.
  #
  # Two kinds of credential reach it:
  #
  #   - An instance wraps a bearer token: an OAuth App user token, a GitHub
  #     App user token (held only while an installation is verified), or an
  #     installation token.
  #   - The class methods that act as the GitHub App sign a JWT with the
  #     App's private key (ActionAgent.github_app_private_key) per request.
  class GithubClient
    API = "https://api.github.com"
    WEB = "https://github.com"
    TOKEN_URL = "#{WEB}/login/oauth/access_token"
    AUTHORIZE_URL = "#{WEB}/login/oauth/authorize"
    API_VERSION = "2022-11-28"
    USER_AGENT = "activeagent-dashboard"
    TIMEOUT_SECONDS = 8
    # 100 per page is GitHub's maximum; five pages bounds a picker at 500.
    PER_PAGE = 100
    MAX_PAGES = 5
    # GitHub refuses an App JWT that expires more than 10 minutes out, or that
    # its own clock sees as issued in the future, so the JWT is backdated a
    # minute and expires nine minutes from now.
    JWT_BACKDATE_SECONDS = 60
    JWT_LIFETIME_SECONDS = 540
    # A user or organization login, as GitHub allows them.
    LOGIN = /\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/
    # "owner/name", as GitHub allows repository names ("." and ".." are not).
    REPOSITORY = %r{\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/(?!\.{1,2}\z)[A-Za-z0-9._-]{1,100}\z}
    OBJECT_ID = /\A\h{40}(?:\h{24})?\z/

    class Error < StandardError
      # The HTTP status GitHub answered with, or nil when it was not reached.
      attr_reader :status
      # The +errors+ of GitHub's answer, each a Hash such as { "resource" =>
      # "PullRequest", "field" => "base", "code" => "invalid", "message" =>
      # "…" }; empty when it carried none.
      attr_reader :errors

      def initialize(message = nil, status: nil, errors: [])
        super(message)
        @status = status
        @errors = errors
      end
    end
    # The token was revoked or expired: the owner has to connect again.
    class Unauthorized < Error; end
    # GitHub minted no token because the installation was removed from its
    # account (404) or suspended (403). +reason+ is :removed or :suspended.
    class InstallationUnavailable < Error
      attr_reader :reason

      def initialize(message = nil, reason:, status: nil)
        super(message, status: status)
        @reason = reason
      end
    end

    class << self
      # GitHub's authorization page. The OAuth App with its scopes by default.
      # The GitHub App's user authorization passes the App's client id and no
      # scope, since a GitHub App's permissions are set on the App.
      def authorize_url(redirect_uri:, state:, client_id: ActionAgent.github_client_id, scope: ActionAgent.github_oauth_scopes)
        query = {
          client_id: client_id,
          redirect_uri: redirect_uri,
          scope: scope,
          state: state,
          allow_signup: "false"
        }.compact.to_query

        "#{AUTHORIZE_URL}?#{query}"
      end

      # Where an admin installs the GitHub App on the repositories they choose.
      def installation_url(state:, slug: ActionAgent.github_app_slug)
        "#{WEB}/apps/#{ERB::Util.url_encode(slug)}/installations/new?#{{ state: state }.to_query}"
      end

      # Where a manifest is posted to create a GitHub App: under the signed-in
      # GitHub user, or under +organization+ when one is named.
      def new_app_url(state:, organization: nil)
        path = organization.present? ? "/organizations/#{ERB::Util.url_encode(organization)}/settings/apps/new" : "/settings/apps/new"
        "#{WEB}#{path}?#{{ state: state }.to_query}"
      end

      # Trades an OAuth code for { access_token:, scope: }, with the OAuth
      # App's credentials unless others are given. A refresh token GitHub
      # sends with an expiring user token is dropped.
      def exchange_code(code:, redirect_uri:, client_id: ActionAgent.github_client_id, client_secret: ActionAgent.github_client_secret)
        uri = URI.parse(TOKEN_URL)
        request = Net::HTTP::Post.new(uri, "Accept" => "application/json", "User-Agent" => USER_AGENT)
        request.set_form_data(client_id: client_id, client_secret: client_secret, code: code, redirect_uri: redirect_uri)
        data = perform(uri, request)
        raise Error, data["error_description"].presence || data["error"] if data["error"].present?
        raise Error, "GitHub returned no access token" if data["access_token"].blank?

        { access_token: data["access_token"], scope: data["scope"].to_s }
      end

      # A JWT that authenticates as the GitHub App: RS256 over the App's
      # private key, issued by the App id.
      #
      # @raise [Error] when the private key is missing or not an RSA key
      # @return [String]
      def app_jwt(now: Time.now)
        payload = { iat: now.to_i - JWT_BACKDATE_SECONDS, exp: now.to_i + JWT_LIFETIME_SECONDS, iss: ActionAgent.github_app_id }
        signing_input = [ { alg: "RS256", typ: "JWT" }, payload ].map { |part| base64url(part.to_json) }.join(".")
        signature = app_private_key.sign(OpenSSL::Digest.new("SHA256"), signing_input)

        "#{signing_input}.#{base64url(signature)}"
      end

      # Mints an installation token, valid for an hour, limited to
      # +permissions+ (e.g. { contents: "read" }) and, when given, to
      # +repository_ids+. The token is returned and kept nowhere.
      #
      # @raise [InstallationUnavailable] when the installation was removed or suspended
      # @return [String]
      def mint_installation_token(installation_id, permissions:, repository_ids: nil)
        body = { permissions: permissions, repository_ids: repository_ids }.compact
        data = app_post("/app/installations/#{Integer(installation_id)}/access_tokens", body)
        data["token"].presence or raise Error, "GitHub returned no installation token"
      rescue Error => e
        raise unavailable_installation(e) || e
      end

      # Trades the code the manifest flow returns for the new App's settings:
      # id, slug, client_id, client_secret, pem and html_url among them.
      def convert_manifest(code)
        raise Error, "GitHub returned an invalid manifest code" unless code.is_a?(String) && code.match?(/\A[A-Za-z0-9_-]{1,200}\z/)

        uri = URI.parse("#{API}/app-manifests/#{code}/conversions")
        perform(uri, Net::HTTP::Post.new(uri, api_headers))
      end

      def perform(uri, request)
        response = Net::HTTP.start(
          uri.host, uri.port,
          use_ssl: true, open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS
        ) { |http| http.request(request) }

        status = response.code.to_i
        raise Unauthorized.new("GitHub rejected the token", status: status) if status == 401
        unless status.between?(200, 299)
          body = error_body(response)
          raise Error.new(refusal_message(response.code, body), status: status, errors: Array(body["errors"]).grep(Hash))
        end

        JSON.parse(response.body.presence || "{}")
      rescue JSON::ParserError
        raise Error, "GitHub answered with something other than JSON"
      rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
        raise Error, "GitHub is unreachable (#{e.class.name})"
      end

      def slice_repository(repo)
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

      def api_headers(authorization = nil)
        {
          "Accept" => "application/vnd.github+json",
          "X-GitHub-Api-Version" => API_VERSION,
          "User-Agent" => USER_AGENT,
          "Authorization" => authorization
        }.compact
      end

      private

      def app_post(path, body)
        uri = URI.parse("#{API}#{path}")
        request = Net::HTTP::Post.new(uri, api_headers("Bearer #{app_jwt}").merge("Content-Type" => "application/json"))
        request.body = body.to_json
        perform(uri, request)
      end

      def app_private_key
        pem = ActionAgent.github_app_private_key
        raise Error, "No GitHub App private key is configured" if pem.blank?

        key = OpenSSL::PKey.read(pem)
        raise Error, "The GitHub App private key is not an RSA key" unless key.is_a?(OpenSSL::PKey::RSA)

        key
      rescue OpenSSL::PKey::PKeyError
        raise Error, "The GitHub App private key could not be read"
      end

      def unavailable_installation(error)
        return nil if error.is_a?(InstallationUnavailable)

        if error.status == 404
          InstallationUnavailable.new("The GitHub App installation was removed", reason: :removed, status: 404)
        elsif error.status == 403 && error.message.match?(/suspend/i)
          InstallationUnavailable.new("The GitHub App installation is suspended", reason: :suspended, status: 403)
        end
      end

      # The status, and GitHub's own message when the body carries one, with
      # the messages of a validation failure's errors after it:
      # "GitHub answered 404 (Not Found)", "GitHub answered 422 (Validation
      # Failed: A pull request already exists for acme:fix.)".
      def refusal_message(code, body)
        errors = Array(body["errors"]).filter_map { |error| error["message"] if error.is_a?(Hash) && error["message"].is_a?(String) }
        detail = [ body["message"].is_a?(String) ? body["message"] : nil, errors.join(" ").presence ].compact.join(": ")
        detail = detail.truncate(300).presence
        detail ? "GitHub answered #{code} (#{detail})" : "GitHub answered #{code}"
      end

      # The JSON object GitHub answered a failed request with, or {}.
      def error_body(response)
        body = JSON.parse(response.body.to_s)
        body.is_a?(Hash) ? body : {}
      rescue JSON::ParserError, TypeError
        {}
      end

      def base64url(bytes)
        Base64.urlsafe_encode64(bytes, padding: false)
      end
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
      paginate do |page|
        get("/user/repos", per_page: PER_PAGE, page: page, sort: "pushed", affiliation: "owner,collaborator,organization_member")
      end
    end

    # The GitHub App's installations a GitHub App user token's user can
    # reach, as GitHub describes them (id, account, repository_selection,
    # permissions, suspended_at).
    def user_installations
      (1..MAX_PAGES).each_with_object([]) do |page, all|
        batch = Array(get("/user/installations", per_page: PER_PAGE, page: page)["installations"])
        all.concat(batch)
        break all if batch.size < PER_PAGE
      end
    end

    # The user's membership in +organization+ ({ "state" =>, "role" => }), or
    # nil when GitHub reports none.
    def organization_membership(organization)
      raise Error, "#{organization.inspect} is not a GitHub login" unless organization.is_a?(String) && organization.match?(LOGIN)

      get("/user/memberships/orgs/#{organization}")
    rescue Error => e
      raise unless e.status.in?([ 403, 404 ])

      nil
    end

    # The repositories an installation token reaches, reduced like
    # #repositories.
    def installation_repositories
      paginate { |page| Array(get("/installation/repositories", per_page: PER_PAGE, page: page)["repositories"]) }
    end

    # --- Publishing through the Git Data API --------------------------------
    #
    # +repository+ is "owner/name". A branch is named without refs/heads/.

    # The commit +branch+ points at, or nil when there is no such branch.
    def branch_head(repository, branch)
      data = get("#{repository_path(repository)}/git/ref/heads/#{branch_path(branch)}")
      data.dig("object", "sha")
    rescue Error => e
      raise unless e.status == 404

      nil
    end

    # The tree a commit records.
    def commit_tree(repository, sha)
      get("#{repository_path(repository)}/git/commits/#{object_id!(sha)}").dig("tree", "sha") or
        raise Error, "GitHub returned no tree for #{sha}"
    end

    # Stores +content+ (bytes) as a blob and returns its sha.
    def create_blob(repository, content)
      created_sha(post("#{repository_path(repository)}/git/blobs", content: Base64.strict_encode64(content.b), encoding: "base64"))
    end

    # A tree of +entries+ on top of +base_tree+: each { path:, mode:, sha: },
    # where a nil sha deletes the path. Returns its sha.
    def create_tree(repository, base_tree:, entries:)
      tree = entries.map { |entry| { path: entry[:path], mode: entry[:mode], type: "blob", sha: entry[:sha] } }
      created_sha(post("#{repository_path(repository)}/git/trees", base_tree: object_id!(base_tree), tree: tree))
    end

    # A commit with no author or committer of its own, so GitHub records and
    # signs it as the token's identity. Returns its sha.
    def create_commit(repository, message:, tree:, parents:)
      body = { message: message, tree: object_id!(tree), parents: parents.map { |parent| object_id!(parent) } }
      created_sha(post("#{repository_path(repository)}/git/commits", body))
    end

    # Creates +branch+ at +sha+. GitHub refuses with 422 when it exists.
    def create_branch(repository, branch, sha)
      post("#{repository_path(repository)}/git/refs", ref: "refs/heads/#{branch}", sha: object_id!(sha))
    end

    # Moves +branch+ to +sha+, which GitHub accepts only as a fast-forward.
    def fast_forward_branch(repository, branch, sha)
      patch("#{repository_path(repository)}/git/refs/heads/#{branch_path(branch)}", sha: object_id!(sha), force: false)
    end

    # Opens a pull request of +head+ into +base+, and returns GitHub's
    # description of it (number, html_url, state, draft, merged).
    def create_pull_request(repository, title:, body:, head:, base:, draft:)
      post("#{repository_path(repository)}/pulls", title: title, body: body.to_s, head: head, base: base, draft: draft)
    end

    def pull_request(repository, number)
      get("#{repository_path(repository)}/pulls/#{Integer(number)}")
    end

    private

    def repository_path(repository)
      raise Error, "#{repository.inspect} is not a GitHub repository name" unless repository.is_a?(String) && repository.match?(REPOSITORY)

      "/repos/#{repository}"
    end

    def branch_path(branch)
      branch.to_s.split("/").map { |part| ERB::Util.url_encode(part) }.join("/")
    end

    def object_id!(sha)
      raise Error, "#{sha.inspect} is not a git object id" unless sha.is_a?(String) && sha.match?(OBJECT_ID)

      sha
    end

    def created_sha(data)
      data["sha"].presence or raise Error, "GitHub returned no sha"
    end

    def post(path, body)
      write(Net::HTTP::Post, path, body)
    end

    def patch(path, body)
      write(Net::HTTP::Patch, path, body)
    end

    def write(verb, path, body)
      uri = URI.parse("#{API}#{path}")
      request = verb.new(uri, self.class.api_headers("Bearer #{@access_token}").merge("Content-Type" => "application/json"))
      request.body = body.to_json
      self.class.perform(uri, request)
    end

    def paginate
      (1..MAX_PAGES).each_with_object([]) do |page, all|
        batch = Array(yield(page))
        all.concat(batch.map { |repo| self.class.slice_repository(repo) })
        break all if batch.size < PER_PAGE
      end
    end

    def get(path, params = {})
      uri = URI.parse("#{API}#{path}")
      uri.query = params.to_query if params.any?
      self.class.perform(uri, Net::HTTP::Get.new(uri, self.class.api_headers("Bearer #{@access_token}")))
    end
  end
end
