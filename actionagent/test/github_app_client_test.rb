# frozen_string_literal: true

require "test_helper"
require_relative "support/github_app"

# The GitHub App settings and the calls GithubClient makes as the App: the
# RS256 JWT, installation token mints, and the installation listing.
class GithubAppClientTest < ActiveSupport::TestCase
  include GithubAppTestHelper

  APP_ENV = %w[GITHUB_APP_ID GITHUB_APP_PRIVATE_KEY GITHUB_APP_SLUG GITHUB_APP_CLIENT_ID GITHUB_APP_CLIENT_SECRET].freeze

  def setup
    @saved_env = APP_ENV.to_h { |name| [ name, ENV.delete(name) ] }
    reset_github_app!
  end

  def teardown
    reset_github_app!
    @saved_env.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  test "an App is configured only when all five settings are present" do
    assert_not ActionAgent.github_app_configured?

    configure_github_app!
    assert ActionAgent.github_app_configured?

    ActionAgent.github_app_client_secret = nil
    assert_not ActionAgent.github_app_configured?, "the client secret is needed to verify an installation"
  end

  test "each setting falls back to its GITHUB_APP_ variable" do
    ENV["GITHUB_APP_ID"] = "123"
    ENV["GITHUB_APP_PRIVATE_KEY"] = GithubAppTestHelper.private_key.to_pem
    ENV["GITHUB_APP_SLUG"] = "from-env"
    ENV["GITHUB_APP_CLIENT_ID"] = "Iv1.env"
    ENV["GITHUB_APP_CLIENT_SECRET"] = "env-secret"

    assert ActionAgent.github_app_configured?
    assert_equal "123", ActionAgent.github_app_id
    assert_equal "from-env", ActionAgent.github_app_slug

    ActionAgent.github_app_slug = "configured"
    assert_equal "configured", ActionAgent.github_app_slug, "a configured value wins over the variable"
  end

  test "a private key written on one line with escaped line breaks is read with real ones" do
    pem = GithubAppTestHelper.private_key.to_pem
    ActionAgent.github_app_private_key = pem.gsub("\n", "\\n")

    assert_equal pem, ActionAgent.github_app_private_key
  end

  test "the App JWT is RS256, issued by the App id, backdated, and expires within ten minutes" do
    configure_github_app!
    now = Time.utc(2026, 10, 2, 12, 0, 0)

    header, payload = verified_jwt(ActionAgent::GithubClient.app_jwt(now: now))

    assert_equal "RS256", header["alg"]
    assert_equal "JWT", header["typ"]
    assert_equal APP_ID, payload["iss"].to_s
    assert_operator payload["iat"], :<, now.to_i, "iat is backdated against clock drift"
    assert_operator payload["iat"], :>=, now.to_i - 60
    assert_operator payload["exp"], :>, now.to_i
    assert_operator payload["exp"] - now.to_i, :<=, 600, "GitHub refuses a JWT that lives longer than ten minutes"
  end

  test "a missing or unreadable private key raises a GitHub error rather than an OpenSSL one" do
    configure_github_app!
    ActionAgent.github_app_private_key = "not a key"

    error = assert_raises(ActionAgent::GithubClient::Error) { ActionAgent::GithubClient.app_jwt }
    assert_match(/private key could not be read/, error.message)
  end

  test "a mint is limited to the repositories and permissions asked for, and returns the token" do
    configure_github_app!
    stub_mint(token: "ghs_minted")

    token = ActionAgent::GithubClient.mint_installation_token(INSTALLATION_ID, permissions: { contents: "read" }, repository_ids: [ 5 ])

    assert_equal "ghs_minted", token
    assert_requested(:post, mint_url, times: 1) do |request|
      JSON.parse(request.body) == { "repository_ids" => [ 5 ], "permissions" => { "contents" => "read" } }
    end
  end

  test "a mint refused for a removed or suspended installation says which" do
    configure_github_app!

    stub_mint(status: 404, message: "Not Found")
    removed = assert_raises(ActionAgent::GithubClient::InstallationUnavailable) do
      ActionAgent::GithubClient.mint_installation_token(INSTALLATION_ID, permissions: { contents: "read" })
    end
    assert_equal :removed, removed.reason

    stub_mint(status: 403, message: "This installation has been suspended")
    suspended = assert_raises(ActionAgent::GithubClient::InstallationUnavailable) do
      ActionAgent::GithubClient.mint_installation_token(INSTALLATION_ID, permissions: { contents: "read" })
    end
    assert_equal :suspended, suspended.reason
  end

  test "any other refused mint is a plain GitHub error carrying GitHub's message" do
    configure_github_app!
    stub_mint(status: 422, message: "There is at least one repository that does not exist or is not accessible")

    error = assert_raises(ActionAgent::GithubClient::Error) do
      ActionAgent::GithubClient.mint_installation_token(INSTALLATION_ID, permissions: { contents: "read" }, repository_ids: [ 1 ])
    end
    assert_not_kind_of ActionAgent::GithubClient::InstallationUnavailable, error
    assert_equal 422, error.status
    assert_match(/GitHub answered 422 \(There is at least one repository/, error.message)
  end

  test "an installation's repositories are listed with the installation token and reduced like a user's" do
    stub_installation_repositories([ repo_payload(5, "acme/shop") ], token: "ghs_listing")

    rows = ActionAgent::GithubClient.new("ghs_listing").installation_repositories

    assert_equal [ "acme/shop" ], rows.map { |repo| repo["full_name"] }
    assert_equal %w[default_branch description full_name html_url id private pushed_at], rows.first.keys.sort
  end

  test "an organization membership GitHub does not report reads as none" do
    stub_request(:get, "https://api.github.com/user/memberships/orgs/acme").to_return(status: 404, body: { message: "Not Found" }.to_json)

    assert_nil ActionAgent::GithubClient.new("ghu_user").organization_membership("acme")
    assert_raises(ActionAgent::GithubClient::Error) { ActionAgent::GithubClient.new("ghu_user").organization_membership("../repos") }
  end
end
