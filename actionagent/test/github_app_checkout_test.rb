# frozen_string_literal: true

require "test_helper"
require_relative "support/github_app"

# Checkout sandboxes through a GitHub App installation: the installation wins
# over the OAuth connection, the provision mints one token limited to the
# repository's contents, and that token reaches the backend and the scrub
# list in memory only.
class GithubAppCheckoutTest < ActionDispatch::IntegrationTest
  include GithubAppTestHelper

  OAUTH_TOKEN = "gho_oauth_checkout_secret"
  # An installation token in GitHub's older format, which no prefix pattern
  # matches: a value only scrubbing by value can mask.
  MINTED = "v1.#{'0123456789abcdef' * 3}"

  # Records the checkout each create was handed, and raises on request with
  # a message echoing the token, as a failing clone might.
  class RecordingBackend
    class << self
      attr_accessor :checkouts, :fail_with_token

      def reset!
        self.checkouts = []
        self.fail_with_token = false
      end
    end

    def create_sandbox(session)
      spec = session.checkout_spec
      self.class.checkouts << spec
      raise "fatal: Authentication failed for https://x-access-token:#{spec[:token]}@github.com/" if self.class.fail_with_token

      { container_name: "recording-#{session.session_id}", url: "http://127.0.0.1:9", mcp_url: "http://127.0.0.1:9/activeagents/mcp" }
    end

    def terminate(_handle) = true
    def status(_handle) = { status: "running" }
    def list_sandboxes = []
    def cleanup_expired = 0
  end

  def setup
    ActionAgent::CodeSession.delete_all
    ActionAgent::SandboxSession.delete_all
    ActionAgent::GithubInstallation.delete_all
    ActionAgent::GithubConnection.delete_all
    configure_github_app!
    RecordingBackend.reset!
    @original_backends = ActionAgent.sandbox_backends
    @original_service = ActionAgent.sandbox_service
    ActionAgent.sandbox_backends = { "recording" => RecordingBackend.name }
    ActionAgent.sandbox_service = :recording
  end

  def teardown
    reset_github_app!
    ActionAgent.sandbox_backends = @original_backends
    ActionAgent.sandbox_service = @original_service
  end

  test "a repository selected on an installation is checked out through it, ahead of the OAuth connection" do
    connect_oauth!(repositories: [ repo_row(5, "acme/shop"), repo_row(6, "acme/docs", default_branch: "trunk") ])
    installation = link_installation!(repositories: [ repo_row(5, "acme/shop") ])

    shop = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "ACME/shop")
    docs = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "acme/docs")

    assert_equal installation.id, shop.github_installation_id
    assert_equal "acme/shop", shop.repository
    assert_equal "main", shop.repository_ref
    assert_equal "app", shop.summary[:checkout_source]
    assert_nil docs.github_installation_id, "a repository only the OAuth connection reaches stays on it"
    assert_equal "oauth", docs.summary[:checkout_source]
    assert_equal OAUTH_TOKEN, docs.checkout_spec[:token]
  end

  test "a removed or suspended installation is passed over when choosing how to check out" do
    link_installation!(repositories: [ repo_row(5, "acme/shop") ], suspended_at: Time.current)

    session = ActionAgent::SandboxSession.new(sandbox_type: "app_runtime", repository: "acme/shop")

    assert_not session.valid?
    assert_match(/removed or suspended: reinstall the GitHub App/, session.errors.full_messages.join)
  end

  test "provisioning mints exactly one checkout token, limited to the repository's contents, and stores it nowhere" do
    installation = link_installation!(repositories: [ repo_row(5, "acme/shop") ])
    stub_mint(token: MINTED)

    post "/activeagents/api/sandboxes", params: { sandbox_type: "app_runtime", repository: "acme/shop" }, as: :json
    assert_response :created, response.body
    assert_not_includes response.body, MINTED
    assert_not_requested :post, mint_url
    session = ActionAgent::SandboxSession.find_by!(session_id: JSON.parse(response.body).dig("sandbox", "session_id"))
    provision = enqueued_jobs.select { |job| job[:job] == ActionAgent::SandboxProvisionJob }.sole
    assert_equal [ session.id ], provision[:args], "the job is handed the session id and nothing else"

    perform_enqueued_jobs

    assert_requested(:post, mint_url, times: 1) do |request|
      JSON.parse(request.body) == { "repository_ids" => [ 5 ], "permissions" => { "contents" => "read" } }
    end
    spec = RecordingBackend.checkouts.sole
    assert_equal MINTED, spec[:token]
    assert_equal "x-access-token", spec[:username]
    assert_equal "https://github.com/acme/shop.git", spec[:clone_url]

    assert session.reload.ready?
    stored = [ session.reload.attributes, installation.reload.attributes ].map(&:to_json).join
    assert_not_includes stored, MINTED
    assert_nil session.checkout_spec[:token], "a fresh read of the session carries no token"

    get "/activeagents/api/sandboxes/#{session.session_id}"
    assert_not_includes response.body, MINTED
  end

  test "the backend and the scrub list get the same minted value" do
    link_installation!(repositories: [ repo_row(5, "acme/shop") ])
    stub_mint(token: MINTED)
    RecordingBackend.fail_with_token = true
    session = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "acme/shop", status: :provisioning)

    ActionAgent::SandboxProvisionJob.perform_now(session.id)

    assert_equal MINTED, RecordingBackend.checkouts.sole[:token]
    session.reload
    assert session.failed?
    assert_includes session.error_message, "x-access-token:[REDACTED]@github.com"
    assert_not_includes session.error_message, MINTED
    assert_requested :post, mint_url, times: 1
  end

  test "reading a checkout's secrets never calls GitHub" do
    link_installation!(repositories: [ repo_row(5, "acme/shop") ])
    mint = stub_mint(token: MINTED)
    session = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "acme/shop")
    session.update_columns(status: ActionAgent::SandboxSession.statuses[:ready])
    code_session = ActionAgent::CodeSession.create!(sandbox_session: session, prompt: "Fix the build")

    assert_equal [], code_session.secrets
    assert_equal [], ActionAgent::SandboxProvisionJob.new.send(:secrets_for, session.reload)
    assert_equal [], ActionAgent::LocalSandboxBackend.new.send(:sandbox_secrets, session, {})
    assert_not_requested mint
  end

  test "a code session's transcript masks a checkout token it no longer knows by value" do
    link_installation!(repositories: [ repo_row(5, "acme/shop") ])
    session = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "acme/shop")
    code_session = ActionAgent::CodeSession.create!(sandbox_session: session, prompt: "Print the remote")
    token = "ghs_#{'Z' * 36}"

    code_session.append_event!({ "type" => "assistant", "text" => "remote: https://x-access-token:#{token}@github.com/acme/shop" })

    assert_not_includes code_session.reload.events.to_json, token
  end

  test "a mint refused for a removed installation marks it and fails the provision with a reinstall message" do
    installation = link_installation!(repositories: [ repo_row(5, "acme/shop") ])
    stub_mint(status: 404, message: "Not Found")
    session = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "acme/shop", status: :provisioning)

    ActionAgent::SandboxProvisionJob.perform_now(session.id)

    assert session.reload.failed?
    assert_match(/GitHub App installation on acme was removed.*Reinstall the GitHub App/m, session.error_message)
    assert installation.reload.removed_at
    assert_empty RecordingBackend.checkouts, "nothing was booted"

    WebMock.reset!
    mint = stub_mint(token: MINTED)
    retry_session = ActionAgent::SandboxSession.create!(sandbox_type: "playwright_mcp", status: :provisioning)
    retry_session.update_columns(sandbox_type: "app_runtime", repository: "acme/shop", github_installation_id: installation.id)
    ActionAgent::SandboxProvisionJob.perform_now(retry_session.id)

    assert retry_session.reload.failed?
    assert_match(/was removed/, retry_session.error_message)
    # A marked installation is not asked again until it is linked again.
    assert_not_requested mint
  end

  test "a mint refused for a suspended installation marks it suspended" do
    installation = link_installation!(repositories: [ repo_row(5, "acme/shop") ])
    stub_mint(status: 403, message: "This installation has been suspended")
    session = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "acme/shop", status: :provisioning)

    ActionAgent::SandboxProvisionJob.perform_now(session.id)

    assert session.reload.failed?
    assert_match(/is suspended/, session.error_message)
    assert installation.reload.suspended_at
    assert_nil installation.removed_at
  end

  test "an unlinked installation makes its checkout unavailable rather than falling back to OAuth" do
    connect_oauth!(repositories: [ repo_row(5, "acme/shop") ])
    installation = link_installation!(repositories: [ repo_row(5, "acme/shop") ])
    session = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "acme/shop", status: :provisioning)
    installation.destroy!

    ActionAgent::SandboxProvisionJob.perform_now(session.id)

    assert session.reload.failed?
    assert_match(/no longer available/, session.error_message)
    assert_empty RecordingBackend.checkouts
  end

  test "an OAuth checkout provisions as before, with no mint" do
    connect_oauth!(repositories: [ repo_row(6, "acme/docs") ])
    mint = stub_mint(token: MINTED)
    session = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: "acme/docs", status: :provisioning)

    ActionAgent::SandboxProvisionJob.perform_now(session.id)

    assert session.reload.ready?
    assert_equal OAUTH_TOKEN, RecordingBackend.checkouts.sole[:token]
    assert_not_requested mint
  end

  private

  def connect_oauth!(repositories:)
    ActionAgent::GithubConnection.create!(access_token: OAUTH_TOKEN, github_user_id: 42, login: "octocat", repositories: repositories)
  end
end
