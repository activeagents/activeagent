# frozen_string_literal: true

require "test_helper"
require_relative "support/github_app"

# Projects on a dashboard whose owner reaches GitHub through a GitHub App
# installation, with or without an OAuth connection beside it: the
# capabilities checklist counts the installation as connected, the picker
# lists its repositories, and the preflight, secret discovery and creation
# read the repository with a token minted for that one repository. A
# repository reached both ways is read through the installation, as its
# sandbox is checked out through it.
class ProjectsGithubAppTest < ActionDispatch::IntegrationTest
  include GithubAppTestHelper

  BASE = "/activeagents/api/projects"
  OAUTH_TOKEN = "gho_projects_app_oauth_token"
  LISTING_TOKEN = "ghs_#{'L' * 36}"
  CONTENTS_TOKEN = "ghs_#{'C' * 36}"

  # Takes a boot spec, so the checklist's boot_spec item holds.
  class BootSpecBackend
    def create_sandbox(session, boot_config: nil)
      { container_name: "app-project-#{session.session_id}", url: "http://127.0.0.1:9" }
    end

    def terminate(_handle) = true
    def status(_handle) = { status: "running" }
    def list_sandboxes = []
    def cleanup_expired = 0
  end

  def setup
    ActionAgent::Project.delete_all
    ActionAgent::ProjectSecret.delete_all
    ActionAgent::EvaluationRun.delete_all
    ActionAgent::Evaluation.delete_all
    ActionAgent::Agent.delete_all
    ActionAgent::SandboxSession.delete_all
    ActionAgent::GithubInstallation.delete_all
    ActionAgent::GithubConnection.delete_all
    WebMock::RequestRegistry.instance.reset!
    configure_github_app!
    @original_backends = ActionAgent.sandbox_backends
    @original_service = ActionAgent.sandbox_service
    ActionAgent.sandbox_backends = { "boot_spec" => BootSpecBackend.name }
    ActionAgent.sandbox_service = "boot_spec"
    stub_mints
  end

  def teardown
    reset_github_app!
    ActionAgent.sandbox_backends = @original_backends
    ActionAgent.sandbox_service = @original_service
    ActionAgent.permission_checker = nil
    ActionAgent.github_client_id = nil
    ActionAgent.github_client_secret = nil
  end

  test "an installation alone counts as connected, and the checklist names the App's callback" do
    link_installation!(repositories: [ repo_row(5, "acme/shop") ])

    get "#{BASE}/capabilities"

    assert_response :success
    body = JSON.parse(response.body)
    assert body["ready"], body["items"].inspect
    assert_equal [ "app", true ], body["github"].values_at("mode", "connected")
    item = body["items"].find { |entry| entry["key"] == "github_connection" }
    assert_equal [ true, "Connected" ], item.values_at("ok", "detail")
  end

  test "with nothing linked the checklist asks for the App to be installed, and preflight is refused" do
    get "#{BASE}/capabilities"

    item = JSON.parse(response.body)["items"].find { |entry| entry["key"] == "github_connection" }
    assert_equal [ false, "Install the GitHub App in Settings → Integrations" ], item.values_at("ok", "fix")

    get "#{BASE}/preflight", params: { repository: "acme/shop" }
    assert_response :unprocessable_entity
    assert_equal "github_not_connected", JSON.parse(response.body)["code"]
  end

  test "a removed or suspended installation does not count, and neither does one while no App is configured" do
    installation = link_installation!(repositories: [ repo_row(5, "acme/shop") ], removed_at: Time.current)

    get "#{BASE}/capabilities"
    assert_equal false, JSON.parse(response.body).dig("github", "connected")

    installation.update!(removed_at: nil)
    reset_github_app!
    skip "GITHUB_APP_* is set in this environment" if ActionAgent.github_app_configured?

    get "#{BASE}/preflight", params: { repository: "acme/shop" }
    assert_response :unprocessable_entity
    assert_equal "github_not_connected", JSON.parse(response.body)["code"]
  end

  test "the picker lists the installation's selection, and everything it reaches to someone who may manage it" do
    link_installation!(repositories: [ repo_row(5, "acme/shop") ])
    stub_installation_repositories([ repo_payload(5, "acme/shop"), repo_payload(6, "acme/billing") ], token: LISTING_TOKEN)

    get "#{BASE}/repositories"

    assert_response :success, response.body
    rows = JSON.parse(response.body)["repositories"].map { |repo| repo.values_at("full_name", "selected", "source") }
    assert_equal [ [ "acme/shop", true, "app" ], [ "acme/billing", false, "app" ] ], rows

    WebMock::RequestRegistry.instance.reset!
    ActionAgent.permission_checker = ->(_user, action, _subject) { action != :manage_github }
    get "#{BASE}/repositories"

    assert_response :success
    assert_equal [ "acme/shop" ], JSON.parse(response.body)["repositories"].map { |repo| repo["full_name"] }
    assert_not_requested(:post, mint_url)
  end

  test "the picker lists the union of the installation's and the connection's repositories, the installation first" do
    connect_oauth!(repositories: [ repo_row(5, "acme/shop"), repo_row(7, "octocat/blog") ])
    link_installation!(repositories: [ repo_row(5, "acme/shop") ])
    stub_installation_repositories([ repo_payload(5, "acme/shop"), repo_payload(6, "acme/billing") ], token: LISTING_TOKEN)
    stub_request(:get, %r{\A#{API}/user/repos}).with(headers: { "Authorization" => "Bearer #{OAUTH_TOKEN}" })
      .to_return(status: 200, body: [ repo_payload(5, "acme/shop"), repo_payload(7, "octocat/blog"), repo_payload(8, "octocat/notes") ].to_json)

    get "#{BASE}/repositories"

    assert_response :success, response.body
    rows = JSON.parse(response.body)["repositories"].map { |repo| repo.values_at("full_name", "selected", "source") }
    assert_equal [ [ "acme/shop", true, "app" ], [ "octocat/blog", true, "oauth" ], [ "acme/billing", false, "app" ],
                   [ "octocat/notes", false, "oauth" ] ], rows
  end

  test "preflight and discovery read a selected repository with a token limited to its contents" do
    link_installation!(repositories: [ repo_row(5, "acme/shop") ])
    stub_repository_files("acme/shop", token: CONTENTS_TOKEN)

    get "#{BASE}/preflight", params: { repository: "acme/shop" }

    assert_response :success, response.body
    body = JSON.parse(response.body)
    assert_equal [ "acme/shop", true, "app" ], body["repository"].values_at("full_name", "selected", "source")
    assert_equal "bootstrap", body.dig("preflight", "status")
    assert_requested(:post, mint_url, body: { permissions: { contents: "read" }, repository_ids: [ 5 ] }.to_json)
    assert_not_includes response.body, CONTENTS_TOKEN

    get "#{BASE}/discover_secrets", params: { repository: "acme/shop" }

    assert_response :success, response.body
    assert_equal [ "STRIPE_SECRET_KEY" ], JSON.parse(response.body)["variables"].map { |variable| variable["name"] }
  end

  test "creating a project from an installation's repository boots its sandbox through the installation" do
    installation = link_installation!(repositories: [ repo_row(5, "acme/shop") ])
    stub_repository_files("acme/shop", token: CONTENTS_TOKEN)

    post BASE, params: { repository: "acme/shop" }, as: :json

    assert_response :created, response.body
    project = ActionAgent::Project.sole
    assert_equal "acme/shop", project.repository

    post "#{BASE}/#{project.id}/boot", as: :json

    assert_response :accepted, response.body
    assert_equal installation.id, project.reload.current_sandbox_session.github_installation_id
  end

  test "a repository the installation reaches but has not selected is found by name and selected on it" do
    connection = connect_oauth!(repositories: [])
    installation = link_installation!(repositories: [ repo_row(5, "acme/shop") ])
    stub_request(:get, "#{API}/repos/acme/billing").with(headers: { "Authorization" => "Bearer #{LISTING_TOKEN}" })
      .to_return(status: 200, body: repo_payload(6, "acme/billing", default_branch: "trunk").to_json)
    stub_repository_files("acme/billing", token: CONTENTS_TOKEN, ref: "trunk")

    post BASE, params: { repository: "acme/billing" }, as: :json

    assert_response :created, response.body
    assert_equal %w[acme/shop acme/billing], installation.reload.repository_names
    assert_equal [], connection.reload.repository_names
    assert_requested(:post, mint_url, body: { permissions: { contents: "read" }, repository_ids: [ 6 ] }.to_json)
    assert_not_requested(:get, %r{\A#{API}/repos/acme/billing}, headers: { "Authorization" => "Bearer #{OAUTH_TOKEN}" })
  end

  test "picking an unselected repository needs :manage_github, and nothing is minted or asked without it" do
    link_installation!(repositories: [ repo_row(5, "acme/shop") ])
    asked = []
    ActionAgent.permission_checker = lambda do |_user, action, subject|
      asked << [ action, subject.class.name ] if action == :manage_github
      action != :manage_github
    end

    get "#{BASE}/preflight", params: { repository: "acme/billing" }

    assert_response :forbidden
    assert_equal [ "forbidden", "manage_github" ], JSON.parse(response.body).values_at("code", "permission")
    assert_equal [ [ :manage_github, "ActionAgent::GithubInstallation" ] ], asked.uniq
    assert_not_requested(:post, mint_url)
  end

  test "a repository selected both ways is read through the installation, one only the connection selected through it" do
    connect_oauth!(repositories: [ repo_row(5, "acme/shop"), repo_row(7, "octocat/blog") ])
    link_installation!(repositories: [ repo_row(5, "acme/shop") ])
    stub_repository_files("acme/shop", token: CONTENTS_TOKEN)
    stub_repository_files("octocat/blog", token: OAUTH_TOKEN)

    get "#{BASE}/preflight", params: { repository: "acme/shop" }
    assert_response :success, response.body
    assert_equal "app", JSON.parse(response.body).dig("repository", "source")
    assert_not_requested(:get, %r{\A#{API}/repos/acme/shop/}, headers: { "Authorization" => "Bearer #{OAUTH_TOKEN}" })

    get "#{BASE}/preflight", params: { repository: "octocat/blog" }
    assert_response :success, response.body
    assert_equal "oauth", JSON.parse(response.body).dig("repository", "source")
    assert_requested(:post, mint_url, times: 1)
  end

  test "an installation GitHub reports removed is marked and asks for a reinstall" do
    installation = link_installation!(repositories: [ repo_row(5, "acme/shop") ])
    stub_mint(status: 404, message: "Not Found")

    get "#{BASE}/preflight", params: { repository: "acme/shop" }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal [ "installation_unavailable", true ], body.values_at("code", "reinstall_required")
    assert_not installation.reload.usable?
  end

  private

  def connect_oauth!(repositories:)
    ActionAgent.github_client_id = "client-id"
    ActionAgent.github_client_secret = "client-secret"
    ActionAgent::GithubConnection.create!(access_token: OAUTH_TOKEN, github_user_id: 42, login: "octocat", repositories: repositories)
  end

  # A listing token for a mint without repository_ids, and a contents token
  # for one limited to a repository.
  def stub_mints
    stub_request(:post, mint_url).with { |request| jwt_signed?(bearer(request)) }.to_return do |request|
      token = JSON.parse(request.body).key?("repository_ids") ? CONTENTS_TOKEN : LISTING_TOKEN
      { status: 201, body: { token: token, expires_at: 1.hour.from_now.iso8601 }.to_json,
        headers: { "Content-Type" => "application/json" } }
    end
  end

  # Serves a supported Rails app from +repository+ at +ref+, answering only
  # requests made with +token+.
  def stub_repository_files(repository, token:, ref: "main")
    commit = Digest::SHA1.hexdigest("#{repository}@#{ref}")
    auth = { "Authorization" => "Bearer #{token}" }
    files = {
      "Gemfile.lock" => "GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (8.0.1)\n    railties (8.0.1)\n\n" \
                        "PLATFORMS\n  ruby\n\nDEPENDENCIES\n  rails\n\nRUBY VERSION\n   ruby 3.3.6p0\n\nBUNDLED WITH\n   2.6.2\n",
      "config/application.rb" => "# app\n",
      ".env.example" => "STRIPE_SECRET_KEY=\n"
    }
    stub_request(:get, "#{API}/repos/#{repository}/commits").with(query: { "sha" => ref, "per_page" => "1" }, headers: auth)
      .to_return(status: 200, body: [ { sha: commit } ].to_json)
    stub_request(:get, "#{API}/repos/#{repository}/git/trees/#{commit}?recursive=1").with(headers: auth)
      .to_return(status: 200, body: { tree: [ { path: ".env.example", type: "blob", size: 20 } ], truncated: false }.to_json)
    stub_request(:get, %r{\A#{API}/repos/#{Regexp.escape(repository)}/contents/}).with(headers: auth).to_return do |request|
      path = URI(request.uri.to_s).path.delete_prefix("/repos/#{repository}/contents/")
      content = files[CGI.unescape(path)]
      if content
        { status: 200, body: { type: "file", encoding: "base64", size: content.bytesize, content: [ content ].pack("m") }.to_json }
      else
        { status: 404, body: { message: "Not Found" }.to_json }
      end
    end
  end
end
