# frozen_string_literal: true

require "test_helper"
require_relative "support/github_app"

# Settings -> Integrations -> Create GitHub App: a self-hosted dashboard
# creates its App from a manifest and is shown the credentials once.
class GithubAppManifestTest < ActionDispatch::IntegrationTest
  include GithubAppTestHelper

  CALLBACK = "/activeagents/api/github_app_manifest/callback"
  CONVERTED = {
    id: 31_337, slug: "activeagent-acme", name: "ActiveAgent acme", client_id: "Iv1.manifestclient",
    client_secret: "manifest-client-secret-#{'s' * 20}", webhook_secret: nil,
    pem: "-----BEGIN RSA PRIVATE KEY-----\nMIIEmanifestkeyline1\nmanifestkeyline2\n-----END RSA PRIVATE KEY-----\n",
    html_url: "https://github.com/apps/activeagent-acme", owner: { login: "acme" }
  }.freeze

  def setup
    ActionAgent::GithubInstallation.delete_all
    ActionAgent::ProviderKey.delete_all
    ActionAgent::ApiKey.delete_all
  end

  def teardown
    ActionAgent.permission_checker = nil
    ActionAgent.multi_tenant = false
    ActionAgent.user_class = nil
    ActionAgent.account_class = nil
    ActionAgent.current_user_resolver = nil
    ActionAgent.current_account_resolver = nil
  end

  test "the manifest names the callbacks, asks for user authorization on install, and requests no webhook or workflows" do
    post "/activeagents/api/github_app_manifest", as: :json

    assert_response :success
    body = JSON.parse(response.body)
    url = URI.parse(body["url"])
    assert_equal "github.com", url.host
    assert_equal "/settings/apps/new", url.path
    assert Rack::Utils.parse_query(url.query)["state"].present?

    manifest = body["manifest"]
    assert_equal "http://www.example.com#{CALLBACK}", manifest["redirect_url"]
    assert_equal [ "http://www.example.com/activeagents/api/github_installations/callback" ], manifest["callback_urls"]
    assert_equal true, manifest["request_oauth_on_install"]
    assert_equal false, manifest["public"]
    assert_nil manifest["hook_attributes"], "the App gets no webhook"
    assert_equal({ "contents" => "write", "pull_requests" => "write", "metadata" => "read", "members" => "read" },
      manifest["default_permissions"])
    assert_operator manifest["name"].length, :<=, 34
  end

  test "an organization's App is created under that organization" do
    post "/activeagents/api/github_app_manifest", params: { organization: "acme" }, as: :json
    assert_equal "/organizations/acme/settings/apps/new", URI.parse(JSON.parse(response.body)["url"]).path

    post "/activeagents/api/github_app_manifest", params: { organization: "../acme" }, as: :json
    assert_response :bad_request
  end

  test "the callback shows the converted credentials once and stores none of them" do
    state = start_manifest
    conversion = stub_request(:post, "https://api.github.com/app-manifests/manifest-code/conversions")
      .to_return(status: 201, body: CONVERTED.to_json, headers: { "Content-Type" => "application/json" })
    counts = stored_counts

    get CALLBACK, params: { code: "manifest-code", state: state }

    assert_response :success
    assert_requested conversion, times: 1
    assert_includes response.body, "GITHUB_APP_ID=31337"
    assert_includes response.body, "GITHUB_APP_SLUG=activeagent-acme"
    assert_includes response.body, "GITHUB_APP_CLIENT_ID=Iv1.manifestclient"
    assert_includes response.body, "GITHUB_APP_CLIENT_SECRET=#{CONVERTED[:client_secret]}"
    assert_includes response.body, 'GITHUB_APP_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----\\nMIIEmanifestkeyline1'
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_match(/default-src 'none'/, response.headers["Content-Security-Policy"])
    assert_no_match(/<script/i, response.body)

    assert_equal counts, stored_counts, "nothing was written to the database"
    assert_not_includes session.to_hash.to_s, CONVERTED[:client_secret]
    assert_not_includes session.to_hash.to_s, "manifestkeyline"

    get CALLBACK, params: { code: "manifest-code", state: state }
    assert_redirected_to "/activeagents/settings?github_app=invalid_state&tab=integrations", "a state is single use"
    assert_requested conversion, times: 1
  end

  test "a bad state is refused without converting the code" do
    conversion = stub_request(:post, %r{https://api.github.com/app-manifests/})
    start_manifest

    get CALLBACK, params: { code: "manifest-code", state: "forged" }
    assert_redirected_to "/activeagents/settings?github_app=invalid_state&tab=integrations"

    get CALLBACK, params: { code: "manifest-code" }
    assert_redirected_to "/activeagents/settings?github_app=invalid_state&tab=integrations"

    assert_not_requested conversion
  end

  test "a failed conversion returns to Settings" do
    state = start_manifest
    stub_request(:post, "https://api.github.com/app-manifests/manifest-code/conversions").to_return(status: 404, body: "{}")

    get CALLBACK, params: { code: "manifest-code", state: state }

    assert_redirected_to "/activeagents/settings?github_app=manifest_error&tab=integrations"
  end

  test "the manifest flow is unavailable when multi_tenant is on" do
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "User" # the dummy app has no Account
    ActionAgent.multi_tenant = true
    account = User.create!(email: "account@example.com", name: "Account", age: 30)
    ActionAgent.current_account_resolver = ->(_controller) { account }
    ActionAgent.current_user_resolver = ->(_controller) { account }
    ActionAgent.permission_checker = ->(*) { true }

    post "/activeagents/api/github_app_manifest", as: :json
    assert_response :not_found
    assert_equal "manifest_unavailable", JSON.parse(response.body)["code"]

    get CALLBACK, params: { code: "manifest-code", state: "any" }
    assert_redirected_to "/activeagents/settings?github_app=manifest_unavailable&tab=integrations"

    get "/activeagents/api/github_connection"
    assert_equal false, JSON.parse(response.body).dig("app", "manifest_available")
  end

  test "the manifest flow answers a denied manage_github" do
    ActionAgent.permission_checker = ->(_user, action, _subject) { action != :manage_github }

    post "/activeagents/api/github_app_manifest", as: :json
    assert_response :forbidden
    assert_equal "manage_github", JSON.parse(response.body)["permission"]

    get CALLBACK, params: { code: "manifest-code", state: "any" }
    assert_redirected_to "/activeagents/settings?github_app=forbidden&tab=integrations"
  end

  private

  def start_manifest
    post "/activeagents/api/github_app_manifest", as: :json
    Rack::Utils.parse_query(URI.parse(JSON.parse(response.body)["url"]).query)["state"]
  end

  def stored_counts
    [ ActionAgent::GithubInstallation, ActionAgent::GithubConnection, ActionAgent::ProviderKey, ActionAgent::ApiKey ].map(&:count)
  end
end
