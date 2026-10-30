# frozen_string_literal: true

require "test_helper"
require_relative "support/github_app"

# POST <mount>/api/github_app/webhooks: GitHub App deliveries, verified by
# their signature, recorded once by X-GitHub-Delivery, and applied to the
# linked installation (or the user's connection) by GithubWebhookJob. The
# payloads are GitHub's, as recorded in test/fixtures/files/github_webhooks,
# and nothing here reaches the network.
class GithubAppWebhooksTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include GithubAppTestHelper

  ENDPOINT = "/activeagents/api/github_app/webhooks"
  SECRET = "webhook-secret-for-tests"
  FIXTURES = File.expand_path("fixtures/files/github_webhooks", __dir__)

  def setup
    ActionAgent::GithubInstallation.delete_all
    ActionAgent::GithubConnection.delete_all
    ActionAgent::GithubWebhookDelivery.delete_all
    configure_github_app!
    ActionAgent.github_app_webhook_secret = SECRET
  end

  def teardown
    reset_github_app!
    ActionAgent.github_app_webhook_secret = nil
    ActionAgent.github_client_id = nil
  end

  test "a delivery with a valid signature is accepted and queued" do
    link_installation!

    assert_enqueued_with(job: ActionAgent::GithubWebhookJob) do
      deliver "installation", "installation_deleted"
    end

    assert_response :accepted
    assert_equal "queued", response.parsed_body["status"]
    delivery = ActionAgent::GithubWebhookDelivery.sole
    assert_equal [ "installation", "deleted", INSTALLATION_ID ], [ delivery.event, delivery.event_action, delivery.installation_id ]
  end

  test "a bad, malformed or missing signature is refused with a 401 and nothing is recorded" do
    installation = link_installation!
    body = fixture("installation_deleted")
    signatures = [
      sign(body, "some-other-secret"),
      sign(body.sub("deleted", "suspend"), SECRET), # signed for a different body
      OpenSSL::HMAC.hexdigest("SHA256", SECRET, body), # no sha256= prefix
      "sha1=#{OpenSSL::HMAC.hexdigest('SHA1', SECRET, body)}",
      "",
      nil
    ]

    signatures.each do |signature|
      post ENDPOINT, params: body, headers: headers("installation", signature: signature)

      assert_response :unauthorized, signature.inspect
    end
    assert_no_enqueued_jobs
    assert_equal 0, ActionAgent::GithubWebhookDelivery.count
    assert_nil installation.reload.removed_at
  end

  test "with no webhook secret configured there is no endpoint" do
    ActionAgent.github_app_webhook_secret = nil
    skip "GITHUB_APP_WEBHOOK_SECRET is set in this environment" if ActionAgent.github_app_webhook_secret

    body = fixture("installation_deleted")
    post ENDPOINT, params: body, headers: headers("installation", signature: sign(body, SECRET))

    assert_response :not_found
    assert_no_enqueued_jobs
  end

  test "the secret falls back to GITHUB_APP_WEBHOOK_SECRET" do
    ActionAgent.github_app_webhook_secret = nil
    with_env("GITHUB_APP_WEBHOOK_SECRET" => "from-the-environment") do
      assert_equal "from-the-environment", ActionAgent.github_app_webhook_secret

      body = fixture("ping")
      post ENDPOINT, params: body, headers: headers("ping", signature: sign(body, "from-the-environment"))
      assert_response :accepted
    end
  end

  test "is exempt from forgery protection, like the other signed endpoints" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    link_installation!

    deliver "installation", "installation_deleted", extra_headers: { "Sec-Fetch-Site" => "cross-site" }

    assert_response :accepted
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "redelivering the same X-GitHub-Delivery changes nothing" do
    installation = link_installation!

    perform_enqueued_jobs do
      deliver "installation", "installation_suspend", delivery: "delivery-1"
      deliver "installation", "installation_unsuspend", delivery: "delivery-2"
      # GitHub's Redeliver on the earlier suspend, after the unsuspend.
      deliver "installation", "installation_suspend", delivery: "delivery-1"
    end

    assert_response :accepted
    assert_equal "duplicate", response.parsed_body["status"]
    assert_nil installation.reload.suspended_at
    assert_equal 2, ActionAgent::GithubWebhookDelivery.count
  end

  test "a delivery that cannot be enqueued is not recorded, so its redelivery is processed" do
    link_installation!
    body = fixture("installation_deleted")

    ActionAgent::GithubWebhookJob.stub(:perform_later, ->(*) { raise "queue unavailable" }) do
      assert_raises(RuntimeError) do
        post ENDPOINT, params: body, headers: headers("installation", signature: sign(body, SECRET), delivery: "delivery-1")
      end
    end
    assert_equal 0, ActionAgent::GithubWebhookDelivery.count

    deliver "installation", "installation_deleted", delivery: "delivery-1"
    assert_equal "queued", response.parsed_body["status"]
  end

  test "deliveries older than the retention window are pruned" do
    ActionAgent::GithubWebhookDelivery.create!(delivery_id: "old", event: "installation", created_at: 8.days.ago)
    ActionAgent::GithubWebhookDelivery.create!(delivery_id: "recent", event: "installation", created_at: 1.day.ago)
    link_installation!

    deliver "installation", "installation_deleted", delivery: "new"

    assert_equal %w[new recent], ActionAgent::GithubWebhookDelivery.order(:delivery_id).pluck(:delivery_id)
  end

  test "uninstalling the App marks the installation removed without a token mint" do
    installation = link_installation!(repositories: [ repo_row(101, "acme/api") ])

    perform_enqueued_jobs { deliver "installation", "installation_deleted" }

    installation.reload
    assert_not_nil installation.removed_at
    assert_equal "removed", installation.status
    assert_not installation.usable?
    assert_equal [ "acme/api" ], installation.repository_names, "the selection is kept for the owner to see"
    assert_not_requested :post, mint_url

    get "/activeagents/api/github_installations"
    assert_equal "removed", response.parsed_body["installations"].sole["status"]
  end

  test "suspending and unsuspending the App toggles suspended_at" do
    installation = link_installation!

    perform_enqueued_jobs { deliver "installation", "installation_suspend" }
    assert_equal Time.iso8601("2026-10-27T15:04:05Z"), installation.reload.suspended_at
    assert_equal "suspended", installation.status

    perform_enqueued_jobs { deliver "installation", "installation_unsuspend" }
    assert_nil installation.reload.suspended_at
    assert_equal "active", installation.status
  end

  test "accepting new permissions records them" do
    installation = link_installation!(permissions: { "contents" => "write" })

    perform_enqueued_jobs { deliver "installation", "installation_new_permissions_accepted" }

    assert_equal "read", installation.reload.permissions["checks"]
    assert_equal "write", installation.permissions["pull_requests"]
  end

  test "removing repositories on GitHub drops them from the owner's selection" do
    installation = link_installation!(repositories: [ repo_row(101, "acme/api"), repo_row(102, "acme/web") ])

    perform_enqueued_jobs { deliver "installation_repositories", "installation_repositories_removed" }

    assert_equal [ "acme/api" ], installation.reload.repository_names
  end

  test "adding repositories on GitHub keeps the selection, and the picker lists the new one" do
    installation = link_installation!(repositories: [ repo_row(101, "acme/api") ])

    perform_enqueued_jobs { deliver "installation_repositories", "installation_repositories_added" }

    assert_equal [ "acme/api" ], installation.reload.repository_names, "nothing is selected for the owner"
    assert_equal "selected", installation.repository_selection

    # The picker asks GitHub what the installation reaches when it opens.
    stub_mint
    stub_installation_repositories([ repo_payload(101, "acme/api"), repo_payload(103, "acme/docs") ])
    get "/activeagents/api/github_installations/#{installation.id}/repositories"
    listed = response.parsed_body["repositories"].to_h { |repo| [ repo["full_name"], repo["selected"] ] }
    assert_equal({ "acme/api" => true, "acme/docs" => false }, listed)
  end

  test "a delivery for an installation no owner linked changes nothing" do
    installation = link_installation!(installation_id: INSTALLATION_ID + 100)

    perform_enqueued_jobs do
      deliver "installation", "installation_deleted"
      deliver "installation", "installation_created"
      deliver "installation_repositories", "installation_repositories_removed"
    end

    assert_response :accepted
    assert_nil installation.reload.removed_at
    assert_equal 1, ActionAgent::GithubInstallation.count, "a new installation is linked only from Settings"
  end

  test "events the dashboard does not handle are accepted and ignored" do
    link_installation!

    deliver "ping", "ping"
    assert_response :accepted
    assert_equal "ignored", response.parsed_body["status"]

    deliver "push", "installation_deleted"
    assert_equal "ignored", response.parsed_body["status"]

    assert_no_enqueued_jobs
    assert_equal 0, ActionAgent::GithubWebhookDelivery.count
  end

  test "a handled event without a delivery id or a JSON object body is refused" do
    body = fixture("installation_deleted")
    post ENDPOINT, params: body, headers: headers("installation", signature: sign(body, SECRET), delivery: nil)
    assert_response :bad_request

    post ENDPOINT, params: "[1]", headers: headers("installation", signature: sign("[1]", SECRET))
    assert_response :bad_request

    assert_no_enqueued_jobs
  end

  test "a form-encoded delivery is read from its payload field" do
    installation = link_installation!
    body = URI.encode_www_form(payload: fixture("installation_deleted"))

    perform_enqueued_jobs do
      post ENDPOINT, params: body, headers: headers("installation", signature: sign(body, SECRET))
        .merge("Content-Type" => "application/x-www-form-urlencoded")
    end

    assert_response :accepted
    assert_not_nil installation.reload.removed_at
  end

  test "revoking the App's authorization deletes the user's connection token when connections go through the App" do
    ActionAgent.github_client_id = CLIENT_ID # the OAuth connection flow authorizes through the App
    connection = connect!(github_user_id: GITHUB_USER_ID)
    other = connect!(github_user_id: GITHUB_USER_ID + 1, user_id: 2)

    perform_enqueued_jobs { deliver "github_app_authorization", "github_app_authorization_revoked" }

    assert_not ActionAgent::GithubConnection.exists?(connection.id)
    assert ActionAgent::GithubConnection.exists?(other.id)
  end

  test "revoking the App's authorization leaves a connection made through a separate OAuth App" do
    ActionAgent.github_client_id = "Ov23.separate-oauth-app"
    connection = connect!(github_user_id: GITHUB_USER_ID)

    perform_enqueued_jobs { deliver "github_app_authorization", "github_app_authorization_revoked" }

    assert ActionAgent::GithubConnection.exists?(connection.id)
  end

  private

  def fixture(name)
    File.read(File.join(FIXTURES, "#{name}.json"))
  end

  def sign(body, secret)
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"
  end

  def headers(event, signature:, delivery: SecureRandom.uuid)
    {
      "Content-Type" => "application/json",
      "X-GitHub-Event" => event,
      "X-GitHub-Delivery" => delivery,
      "X-GitHub-Hook-Installation-Target-Type" => "integration",
      "X-Hub-Signature-256" => signature
    }.compact
  end

  def deliver(event, name, delivery: SecureRandom.uuid, extra_headers: {})
    body = fixture(name)
    post ENDPOINT, params: body, headers: headers(event, signature: sign(body, SECRET), delivery: delivery).merge(extra_headers)
  end

  # Without validation: a single-user dashboard allows one connection, and
  # this stands in for two owners' connections.
  def connect!(github_user_id:, user_id: nil)
    connection = ActionAgent::GithubConnection.new(
      access_token: "gho_#{SecureRandom.hex(18)}", github_user_id: github_user_id, login: "octocat", user_id: user_id
    )
    connection.save!(validate: false)
    connection
  end

  def with_env(values)
    previous = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end
end
