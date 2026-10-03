# frozen_string_literal: true

require "test_helper"
require_relative "support/github_app"
require_relative "support/staged_checkout_backend"

# Opening a draft pull request from a checkout sandbox: the preview of what
# would be published, the publish through GitHub's Git Data API under a
# token minted for the one repository, the refusals around it, the patch to
# download instead, and the pull request's status afterwards. GitHub is
# stubbed; the sandbox's files come from StagedCheckoutBackend.
class DraftPullRequestsTest < ActionDispatch::IntegrationTest
  include GithubAppTestHelper
  include ActiveJob::TestHelper

  REPO = "acme/shop"
  BASE = "b" * 40
  BASE_TREE = "c" * 40
  WRITE_TOKEN = "ghs_#{'W' * 36}"
  STATUS_TOKEN = "ghs_#{'S' * 36}"
  CLAUDE_KEY = "sk-ant-api03-draftPullRequestSecret_0123"
  OAUTH_TOKEN = "gho_#{'O' * 36}"
  # What GitHub answers a draft pull request in a repository without them.
  DRAFT_REFUSAL = {
    message: "Validation Failed",
    errors: [ { resource: "PullRequest", code: "custom", message: "Draft pull requests are not supported in this repository." } ]
  }.freeze
  BASE_PATH = "/activeagents/api/sandboxes"

  def setup
    ActionAgent::DraftPullRequest.delete_all
    ActionAgent::CodeSession.delete_all
    ActionAgent::SandboxSession.delete_all
    ActionAgent::GithubInstallation.delete_all
    ActionAgent::GithubConnection.delete_all
    ActionAgent::ProviderKey.delete_all
    StagedCheckoutBackend.reset_checkouts!
    configure_github_app!
    @original_backends = ActionAgent.sandbox_backends
    @original_service = ActionAgent.sandbox_service
    ActionAgent.sandbox_backends = { "staged" => StagedCheckoutBackend.name }
    ActionAgent.sandbox_service = :staged
    @calls = []
  end

  def teardown
    reset_github_app!
    StagedCheckoutBackend.reset_checkouts!
    ActionAgent.sandbox_backends = @original_backends
    ActionAgent.sandbox_service = @original_service
    ActionAgent.permission_checker = nil
    ActionAgent.multi_tenant = false
    ActionAgent.user_class = nil
    ActionAgent.account_class = nil
    ActionAgent.current_user_resolver = nil
    ActionAgent.current_account_resolver = nil
    clear_enqueued_jobs
  end

  test "a publish writes blobs, a tree on the checkout commit's tree, a commit, a new branch and a draft pull request" do
    sandbox = app_sandbox!
    stage!(sandbox)
    stub_github!

    preview = preview!(sandbox)
    post "#{BASE_PATH}/#{sandbox.session_id}/pull_request", params: {
      title: "Add gadgets", body: "From the sandbox.", branch: "activeagent/gadgets",
      files: selection(preview, "README.md", "app/models/gadget.rb", "lib/old.rb")
    }, as: :json
    assert_response :accepted, response.body
    queued = enqueued_jobs.select { |job| job[:job] == ActionAgent::DraftPullRequestJob }.sole
    assert_equal [ ActionAgent::DraftPullRequest.sole.id ], queued[:args], "the job is handed the record id and nothing else"
    assert_not_requested :post, mint_url

    perform_enqueued_jobs

    assert_requested(:post, mint_url, times: 1) do |request|
      JSON.parse(request.body) == { "repository_ids" => [ 5 ], "permissions" => { "contents" => "write", "pull_requests" => "write" } }
    end
    writes = @calls.reject { |call| call[:method] == :get }
    assert_equal %w[blobs blobs trees commits refs pulls], writes.map { |call| call[:endpoint] }
    assert(writes.all? { |call| call[:token] == WRITE_TOKEN }, "every write uses the one minted token")
    assert_equal [ "# Shop v2\n", "class Gadget; end\n" ], writes.first(2).map { |call| Base64.decode64(call[:body]["content"]) }

    tree = writes[2][:body]
    assert_equal BASE_TREE, tree["base_tree"]
    assert_equal [
      { "path" => "README.md", "mode" => "100644", "type" => "blob", "sha" => "blob-1".ljust(40, "0") },
      { "path" => "app/models/gadget.rb", "mode" => "100644", "type" => "blob", "sha" => "blob-2".ljust(40, "0") },
      { "path" => "lib/old.rb", "mode" => "100644", "type" => "blob", "sha" => nil }
    ], tree["tree"]
    commit = writes[3][:body]
    assert_equal [ BASE ], commit["parents"]
    assert_equal "Add gadgets\n\nFrom the sandbox.", commit["message"]
    assert_not commit.key?("author"), "GitHub records the App as the author and signs the commit"
    assert_equal({ "ref" => "refs/heads/activeagent/gadgets", "sha" => "d" * 40 }, writes[4][:body])
    assert_equal({ "title" => "Add gadgets", "body" => "From the sandbox.", "head" => "activeagent/gadgets", "base" => "main", "draft" => true },
      writes[5][:body])

    record = ActionAgent::DraftPullRequest.sole
    assert_equal "published", record.status
    assert_equal [ 12, "open", true, "app", "d" * 40 ], [ record.number, record.state, record.draft, record.credential_kind, record.head_commit ]

    get "#{BASE_PATH}/#{sandbox.session_id}/pull_request"
    body = JSON.parse(response.body)
    assert_equal "https://github.com/acme/shop/pull/12", body.dig("pull_request", "url")
    assert_not_includes response.body, WRITE_TOKEN
  end

  test "the preview shows each file's diff and refuses what is never published" do
    sandbox = app_sandbox!
    stage!(sandbox, working: {
      ".github/workflows/ci.yml" => "on: [push, pull_request]\n",
      "config/link" => { content: "../../etc/passwd", mode: "120000" },
      "vendor/lib" => { content: "", mode: "160000" },
      "big.txt" => "x" * (ActionAgent::DraftPullRequestPublisher::MAX_FILE_BYTES + 1),
      "config/leak.yml" => "anthropic: #{CLAUDE_KEY}\n",
      "notes.txt" => "token ghp_#{'a' * 36}\n"
    })
    connect_claude_key!

    preview = preview!(sandbox)

    files = preview["files"].index_by { |file| file["path"] }
    assert_equal({
      ".github/workflows/ci.yml" => "excluded", "app/models/gadget.rb" => nil, "big.txt" => "too_large", "config/leak.yml" => "secret",
      "config/link" => "symlink", "lib/old.rb" => nil, "notes.txt" => "secret", "README.md" => nil, "vendor/lib" => "submodule"
    }, files.transform_values { |file| file["refusal"] })
    assert_match(/^-# Shop\n\+# Shop v2\n/, files["README.md"]["diff"])
    assert_match(/^\+\+\+ \/dev\/null$/, files["lib/old.rb"]["diff"])
    assert_nil files["config/leak.yml"]["diff"], "a file holding a secret is never shown"
    assert_not_includes response.body, CLAUDE_KEY
    assert_not_includes response.body, "ghp_#{'a' * 36}"
    assert files["README.md"]["digest"].present?
    assert_equal "activeagent/sandbox-#{sandbox.session_id.first(8)}", preview["suggested_branch"]
  end

  test "only allowlisted paths are published, and .github/** never is, even when allowlisted" do
    sandbox = app_sandbox!
    stage!(sandbox, working: { ".github/workflows/ci.yml" => "on: [push, pull_request]\n" })

    preview = preview!(sandbox, allowlist: [ "app/**", ".github/**" ])

    refusals = preview["files"].to_h { |file| [ file["path"], file["refusal"] ] }
    assert_nil refusals["app/models/gadget.rb"]
    assert_equal "not_allowed", refusals["README.md"]
    assert_equal "excluded", refusals[".github/workflows/ci.yml"]

    publish!(sandbox, preview_files: preview!(sandbox), paths: [ "README.md" ], allowlist: [ "app/**" ])
    assert_response :unprocessable_entity
    assert_equal "not_publishable", JSON.parse(response.body)["code"]

    publish!(sandbox, preview_files: preview!(sandbox), paths: [ ".github/workflows/ci.yml" ], forge: true)
    assert_response :unprocessable_entity
    assert_equal 0, ActionAgent::DraftPullRequest.count
  end

  test "a file holding a sandbox secret or a GitHub token refuses the publish, naming the file and never the value" do
    sandbox = app_sandbox!
    connect_claude_key!
    stage!(sandbox, working: { "config/leak.yml" => "key: #{CLAUDE_KEY}\n", "notes.txt" => "gho_#{'z' * 36}\n" })
    preview = preview!(sandbox)

    [ "config/leak.yml", "notes.txt" ].each do |path|
      publish!(sandbox, preview_files: preview, paths: [ path ], forge: true)

      assert_response :unprocessable_entity
      body = JSON.parse(response.body)
      assert_equal "secret", body["code"]
      assert_includes body["error"], path
      assert_not_includes response.body, CLAUDE_KEY
      assert_not_includes response.body, "gho_#{'z' * 36}"
    end
  end

  test "content changed after the preview refuses the publish, at the request and in the job" do
    sandbox = app_sandbox!
    stage!(sandbox)
    stub_github!
    preview = preview!(sandbox)

    stage!(sandbox, readme: "# Shop v3\n")
    publish!(sandbox, preview_files: preview, paths: [ "README.md" ])
    assert_response :conflict
    assert_equal "changed_since_preview", JSON.parse(response.body)["code"]

    preview = preview!(sandbox)
    publish!(sandbox, preview_files: preview, paths: [ "README.md" ])
    assert_response :accepted
    stage!(sandbox, readme: "# Shop v4\n")
    perform_enqueued_jobs

    record = ActionAgent::DraftPullRequest.sole
    assert_equal [ "failed", "changed_since_preview" ], [ record.status, record.error_code ]
    assert_not_requested :post, "#{GithubAppTestHelper::API}/repos/#{REPO}/git/blobs"
  end

  test "an existing branch is refused and never overwritten" do
    sandbox = app_sandbox!
    stage!(sandbox)
    stub_github!(branch_head: "e" * 40)

    publish!(sandbox, preview_files: preview!(sandbox), paths: [ "README.md" ])
    perform_enqueued_jobs

    record = ActionAgent::DraftPullRequest.sole
    assert_equal [ "failed", "branch_exists" ], [ record.status, record.error_code ]
    assert(@calls.none? { |call| call[:endpoint] == "refs" }, "no ref is written")
    assert_not_requested :patch, %r{/git/refs/}
  end

  test "a branch created by someone else between the check and the write is refused too" do
    sandbox = app_sandbox!
    stage!(sandbox)
    stub_github!(create_ref_status: 422)

    publish!(sandbox, preview_files: preview!(sandbox), paths: [ "README.md" ])
    perform_enqueued_jobs

    assert_equal "branch_exists", ActionAgent::DraftPullRequest.sole.error_code
    assert(@calls.none? { |call| call[:endpoint] == "pulls" })
  end

  test "updating the pull request fast-forwards its branch without force, and a branch that moved is refused" do
    sandbox = app_sandbox!
    stage!(sandbox)
    stub_github!
    publish!(sandbox, preview_files: preview!(sandbox), paths: [ "README.md", "app/models/gadget.rb" ])
    perform_enqueued_jobs
    published = ActionAgent::DraftPullRequest.sole
    assert_equal "d" * 40, published.head_commit

    stage!(sandbox, readme: "# Shop v3\n")
    @calls.clear
    stub_github!(branch_head: published.head_commit, commit_sha: "f" * 40)
    post "#{BASE_PATH}/#{sandbox.session_id}/pull_request",
      params: { update: true, files: selection(preview!(sandbox), "README.md"), message: "Tidy the README", title: "Ignored" }, as: :json
    assert_response :accepted, response.body
    perform_enqueued_jobs

    published.reload
    assert_equal [ "published", "update", "f" * 40 ], [ published.status, published.operation, published.head_commit ]
    writes = @calls.reject { |call| call[:method] == :get }
    assert_equal %w[blobs trees commits refs], writes.map { |call| call[:endpoint] }, "the pull request itself is not written"
    assert_equal BASE_TREE, writes[1][:body]["base_tree"]
    assert_equal [ "README.md" ], writes[1][:body]["tree"].map { |entry| entry["path"] },
      "the branch holds the checkout commit's tree with the ticked files on top, so an unticked file returns to it"
    assert_equal [ "d" * 40 ], writes[2][:body]["parents"]
    assert_equal "Tidy the README", writes[2][:body]["message"]
    assert_equal :patch, writes[3][:method]
    assert_equal({ "sha" => "f" * 40, "force" => false }, writes[3][:body])
    assert_equal [ "Add gadgets", [ "README.md" ] ], [ published.title, published.files.map { |file| file["path"] } ]
    assert_equal 1, ActionAgent::DraftPullRequest.count, "an update opens no second pull request"

    @calls.clear
    stub_github!(branch_head: "9" * 40)
    post "#{BASE_PATH}/#{sandbox.session_id}/pull_request",
      params: { update: true, files: selection(preview!(sandbox), "README.md") }, as: :json
    perform_enqueued_jobs

    assert_equal [ "failed", "branch_moved" ], [ published.reload.status, published.error_code ]
    assert_equal "f" * 40, published.head_commit
    assert(@calls.none? { |call| call[:endpoint] == "refs" }, "a moved branch is never written")
  end

  test "a draft GitHub refuses keeps the branch and the compare link, and only a second request opens a regular pull request" do
    sandbox = app_sandbox!
    stage!(sandbox)
    stub_github!(draft_refused: true)

    publish!(sandbox, preview_files: preview!(sandbox), paths: [ "README.md" ])
    perform_enqueued_jobs

    record = ActionAgent::DraftPullRequest.sole
    assert_equal [ "draft_refused", "draft_refused" ], [ record.status, record.error_code ]
    assert_equal "https://github.com/acme/shop/compare/main...activeagent/gadgets?expand=1", record.compare_url
    assert_equal "d" * 40, record.head_commit, "the branch stays"
    pulls = @calls.select { |call| call[:endpoint] == "pulls" }
    assert_equal [ true ], pulls.map { |call| call[:body]["draft"] }, "no regular pull request is opened on its own"

    post "#{BASE_PATH}/#{sandbox.session_id}/pull_request", params: { regular: true }, as: :json
    assert_response :accepted, response.body
    perform_enqueued_jobs

    record.reload
    assert_equal [ "published", 12, false ], [ record.status, record.number, record.draft ]
    assert_equal [ true, false ], @calls.select { |call| call[:endpoint] == "pulls" }.map { |call| call[:body]["draft"] }
    assert_equal 1, @calls.count { |call| call[:endpoint] == "blobs" }, "the branch is not pushed again"
  end

  test "a publisher that allows a regular pull request opens one when the draft is refused" do
    sandbox = app_sandbox!
    stage!(sandbox)
    stub_github!(draft_refused: true)
    publisher = ActionAgent::DraftPullRequestPublisher.new(sandbox)
    changes = publisher.changes
    files = publisher.select!(changes, changes.publishable.to_h { |file| [ file.path, file.digest ] })
    record = sandbox.draft_pull_requests.create!(
      repository: REPO, branch: "activeagent/gadgets", title: "Add gadgets", base_commit: BASE,
      files: files.map { |file| { "path" => file.path, "status" => file.status, "mode" => file.mode, "digest" => file.digest } }
    )

    publisher.publish!(record, allow_non_draft: true)

    assert_equal [ "published", false ], [ record.status, record.draft ]
  end

  test "the patch is offered when there is no writing installation, and holds exactly the publishable files" do
    sandbox = app_sandbox!(permissions: { contents: "read", metadata: "read" })
    stage!(sandbox, working: { ".github/workflows/ci.yml" => "on: [push]\n", "config/link" => { content: "x", mode: "120000" } })

    get "#{BASE_PATH}/#{sandbox.session_id}/pull_request"
    publishing = JSON.parse(response.body)["publishing"]
    assert_equal [ false, true, "no_credential" ], publishing.values_at("available", "patch_available", "refusal_code")

    publish!(sandbox, preview_files: preview!(sandbox), paths: [ "README.md" ])
    assert_response :unprocessable_entity
    assert JSON.parse(response.body)["patch_available"]

    get "#{BASE_PATH}/#{sandbox.session_id}/pull_request/patch", params: { title: "Add gadgets" }
    assert_response :success
    assert_equal "text/x-diff", response.media_type
    assert_match(/attachment; filename="acme-shop-#{sandbox.session_id.first(8)}\.patch"/, response.headers["Content-Disposition"])
    patched = response.body.scan(%r{^diff --git a/(\S+)}).flatten
    assert_equal [ "README.md", "app/models/gadget.rb", "lib/old.rb" ], patched
    assert_match(/^Subject: \[PATCH\] Add gadgets$/, response.body)
    assert_not_requested :post, %r{access_tokens}

    get "#{BASE_PATH}/#{sandbox.session_id}/pull_request/patch", params: { paths: [ "README.md" ] }
    assert_equal [ "README.md" ], response.body.scan(%r{^diff --git a/(\S+)}).flatten
  end

  test "GitHub refusing a write fails the publish and offers the patch" do
    [ 403, 404 ].each do |status|
      ActionAgent::DraftPullRequest.delete_all
      sandbox = app_sandbox!
      stage!(sandbox)
      stub_github!(blob_status: status)

      publish!(sandbox, preview_files: preview!(sandbox), paths: [ "README.md" ])
      perform_enqueued_jobs

      record = ActionAgent::DraftPullRequest.sole
      assert_equal [ "failed", "write_refused" ], [ record.status, record.error_code ], status
      get "#{BASE_PATH}/#{sandbox.session_id}/pull_request"
      assert JSON.parse(response.body).dig("publishing", "patch_available")
    end
  end

  test "the OAuth connection publishes as the user who connected it only, and with a scope that can write" do
    account, member = multi_tenant!
    other = User.create!(email: "other@example.com", name: "Other", age: 30)
    connection = connect_oauth!(scopes: "repo,read:user", account_id: account.id, user_id: member.id)
    sandbox = oauth_sandbox!(account_id: account.id, user_id: member.id)
    stage!(sandbox)
    stub_github!(token: OAUTH_TOKEN)

    publish!(sandbox, preview_files: preview!(sandbox), paths: [ "README.md" ])
    assert_response :accepted, response.body
    perform_enqueued_jobs
    record = ActionAgent::DraftPullRequest.sole
    assert_equal [ "published", "oauth", member.id ], [ record.status, record.credential_kind, record.user_id ]
    assert(@calls.all? { |call| call[:token] == OAUTH_TOKEN })
    assert_not_requested :post, %r{access_tokens}

    {
      [ nil, "repo" ] => /does not record who connected it/,
      [ other.id, "repo" ] => /Only the user who connected GitHub \(@octocat\)/,
      [ member.id, "read:user" ] => /do not allow writing to acme\/shop/
    }.each do |(user_id, scopes), message|
      connection.update_columns(user_id: user_id, scopes: scopes)
      get "#{BASE_PATH}/#{sandbox.session_id}/pull_request"
      publishing = JSON.parse(response.body)["publishing"]
      assert_not publishing["available"], scopes
      assert_match message, publishing["refusal"]
      assert publishing["patch_available"]
    end

    connection.update_columns(user_id: member.id, scopes: "public_repo")
    connection.update!(repositories: [ repo_row(5, REPO).merge("private" => false) ])
    get "#{BASE_PATH}/#{sandbox.session_id}/pull_request"
    assert JSON.parse(response.body).dig("publishing", "available"), "public_repo writes to a public repository"
  end

  test "the job asks the OAuth rules again for the user who asked to publish" do
    account, member = multi_tenant!
    connection = connect_oauth!(scopes: "repo", account_id: account.id, user_id: member.id)
    sandbox = oauth_sandbox!(account_id: account.id, user_id: member.id)
    stage!(sandbox)
    stub_github!(token: OAUTH_TOKEN)
    publish!(sandbox, preview_files: preview!(sandbox), paths: [ "README.md" ])
    assert_response :accepted

    connection.update_columns(user_id: member.id + 1000)
    perform_enqueued_jobs

    assert_equal [ "failed", "no_credential" ], ActionAgent::DraftPullRequest.sole.slice(:status, :error_code).values
    assert_empty @calls
  end

  test "a single-user install checks only the OAuth connection's scopes" do
    connect_oauth!(scopes: "repo")
    sandbox = oauth_sandbox!
    stage!(sandbox)

    get "#{BASE_PATH}/#{sandbox.session_id}/pull_request"

    publishing = JSON.parse(response.body)["publishing"]
    assert_equal [ true, "oauth" ], publishing.values_at("available", "credential")
  end

  test "publishing is refused with 403 when the permission checker denies it, also when the job asks again" do
    sandbox = app_sandbox!
    stage!(sandbox)
    stub_github!
    asked = []
    allowed = false
    ActionAgent.permission_checker = lambda { |_user, action, subject|
      asked << [ action, subject.class ]
      allowed
    }
    preview = preview!(sandbox)

    publish!(sandbox, preview_files: preview, paths: [ "README.md" ])
    assert_response :forbidden
    assert_equal "publish_pull_request", JSON.parse(response.body)["permission"]
    assert_equal [ [ :publish_pull_request, ActionAgent::DraftPullRequest ] ], asked

    allowed = true
    publish!(sandbox, preview_files: preview, paths: [ "README.md" ])
    assert_response :accepted
    allowed = false
    perform_enqueued_jobs

    record = ActionAgent::DraftPullRequest.sole
    assert_equal [ "failed", "forbidden" ], [ record.status, record.error_code ]
    assert_not_requested :post, mint_url
  end

  test "multi-tenant: a checker that raises or answers nil denies publishing" do
    account, member = multi_tenant!
    sandbox = app_sandbox!(account_id: account.id, user_id: member.id)
    stage!(sandbox)
    preview = preview!(sandbox)

    [ ->(*) { raise "policy service unavailable" }, ->(*) { nil } ].each do |checker|
      ActionAgent.permission_checker = checker
      publish!(sandbox, preview_files: preview, paths: [ "README.md" ])
      assert_response :forbidden
    end
  end

  test "publishing is refused for a sandbox that is not live, and on a backend that cannot read files" do
    sandbox = app_sandbox!
    stage!(sandbox)
    preview = preview!(sandbox)

    { completed: /completed/, failed: /failed/, expired: /expired/ }.each do |status, message|
      sandbox.update_columns(status: ActionAgent::SandboxSession.statuses[status])
      publish!(sandbox, preview_files: preview, paths: [ "README.md" ])
      assert_response :unprocessable_entity
      body = JSON.parse(response.body)
      assert_equal "not_live", body["code"]
      assert_match message, body["error"]
    end

    sandbox.update_columns(status: ActionAgent::SandboxSession.statuses[:ready], expires_at: 1.minute.ago)
    post "#{BASE_PATH}/#{sandbox.session_id}/pull_request/preview", as: :json
    assert_match(/expired/, JSON.parse(response.body)["error"])

    sandbox.update_columns(expires_at: 1.hour.from_now)
    ActionAgent.sandbox_backends = { "bare" => BareBackend.name, "no_base" => NoBaseBackend.name }
    { bare: /cannot read a sandbox's files/, no_base: /cannot read the commit a checkout was cloned at/ }.each do |backend, message|
      ActionAgent.sandbox_service = backend
      post "#{BASE_PATH}/#{sandbox.session_id}/pull_request/preview", as: :json
      assert_response :unprocessable_entity
      body = JSON.parse(response.body)
      assert_equal "unsupported", body["code"], backend
      assert_match message, body["error"]
      get "#{BASE_PATH}?sandbox_type=app_runtime"
      assert_equal false, JSON.parse(response.body)["pull_requests_supported"], backend
    end
    assert_equal 0, ActionAgent::DraftPullRequest.count
  end

  test "one publish at a time per sandbox" do
    sandbox = app_sandbox!
    stage!(sandbox)
    preview = preview!(sandbox)

    publish!(sandbox, preview_files: preview, paths: [ "README.md" ])
    assert_response :accepted
    publish!(sandbox, preview_files: preview, paths: [ "README.md" ], branch: "activeagent/other")
    assert_response :conflict
  end

  test "an invalid branch name is refused before anything is read or written" do
    sandbox = app_sandbox!
    stage!(sandbox)
    preview = preview!(sandbox)

    [ "", "has space", "a..b", "-leading", "trailing/", "x.lock", ".hidden", "a@{b", "a//b" ].each do |branch|
      publish!(sandbox, preview_files: preview, paths: [ "README.md" ], branch: branch)
      assert_response :unprocessable_entity
      assert_equal "invalid_branch", JSON.parse(response.body)["code"], branch.inspect
    end
  end

  test "a publish carries at most MAX_TOTAL_BYTES, and a preview stops reading past twice that" do
    sandbox = app_sandbox!
    limit = ActionAgent::DraftPullRequestPublisher::MAX_FILE_BYTES - 1
    files = (1..22).to_h { |n| [ format("data/%02d.txt", n), "x" * limit ] }
    StagedCheckoutBackend.stage_checkout(sandbox.session_id, base_commit: BASE, base: {}, working: files)
    publisher = ActionAgent::DraftPullRequestPublisher.new(sandbox)

    changes = publisher.changes

    refusals = changes.files.map(&:refusal)
    assert_equal [ nil ] * 21, refusals.first(21), "files are read until twice the publish limit is passed"
    assert_equal [ "over_total" ], refusals.last(1)
    error = assert_raises(ActionAgent::DraftPullRequestPublisher::Refused) do
      publisher.select!(changes, changes.publishable.first(11).to_h { |file| [ file.path, file.digest ] })
    end
    assert_equal "too_large", error.code
    assert_equal 10, publisher.select!(changes, changes.publishable.first(10).to_h { |file| [ file.path, file.digest ] }).size
  end

  test "no publishing tool is offered to agents or over the MCP facade" do
    names = ActionAgent::AgentToolbox::DEFINITIONS.keys + ActionAgent::AgentToolbox::FUNCTIONS.keys + ActionAgent::Agent::AVAILABLE_TOOLS
    key = ActionAgent::ApiKey.create!(name: "Harness")
    post "/activeagents/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
      headers: { "Content-Type" => "application/json", "Authorization" => "Bearer #{key.token}" }
    names += JSON.parse(response.body).dig("result", "tools").map { |tool| tool["name"] }

    assert names.any?
    assert_empty names.grep(/pull_request|publish|push|commit/i)
  end

  test "the pull request's state is read again at most once a minute" do
    sandbox = app_sandbox!
    stage!(sandbox)
    stub_github!
    publish!(sandbox, preview_files: preview!(sandbox), paths: [ "README.md" ])
    perform_enqueued_jobs
    record = ActionAgent::DraftPullRequest.sole
    stub_mint(token: STATUS_TOKEN)
    states = [ { state: "closed", draft: false }, { state: "closed", merged: true, draft: false } ]
    pull = stub_request(:get, "#{GithubAppTestHelper::API}/repos/#{REPO}/pulls/12")
      .with(headers: { "Authorization" => "Bearer #{STATUS_TOKEN}" })
      .to_return { { status: 200, body: { number: 12, merged: false }.merge(states.first).to_json } }

    get "#{BASE_PATH}/#{sandbox.session_id}/pull_request"
    assert_equal "open", JSON.parse(response.body).dig("pull_request", "state"), "read less than a minute ago"
    assert_not_requested pull

    travel 61.seconds do
      get "#{BASE_PATH}/#{sandbox.session_id}/pull_request"
      assert_equal "closed", JSON.parse(response.body).dig("pull_request", "state")
      get "#{BASE_PATH}/#{sandbox.session_id}/pull_request"
      assert_requested pull, times: 1
    end
    assert_requested(:post, mint_url) do |request|
      JSON.parse(request.body) == { "repository_ids" => [ 5 ], "permissions" => { "pull_requests" => "read" } }
    end

    states.shift
    travel 3.minutes do
      get "#{BASE_PATH}/#{sandbox.session_id}/pull_request"
      assert_equal "merged", JSON.parse(response.body).dig("pull_request", "state")
    end
    assert_equal "merged", record.reload.state
  end

  test "a sandbox of another account is not found, also when the caller opened it" do
    _account, member = multi_tenant!
    theirs = User.create!(email: "theirs@example.com", name: "Theirs", age: 30)
    ActionAgent.permission_checker = ->(*) { true }
    sandbox = app_sandbox!(account_id: theirs.id, user_id: member.id)
    stage!(sandbox)

    post "#{BASE_PATH}/#{sandbox.session_id}/pull_request/preview", as: :json
    assert_response :not_found
    get "#{BASE_PATH}/#{sandbox.session_id}/pull_request/patch"
    assert_response :not_found
  end

  test "a branch with no pull request is never updated: it is opened as a regular pull request when the draft was refused" do
    sandbox = app_sandbox!
    stage!(sandbox)
    stub_github!(draft_refused: true)
    publish!(sandbox, preview_files: preview!(sandbox), paths: [ "README.md" ])
    perform_enqueued_jobs
    record = ActionAgent::DraftPullRequest.sole
    assert_equal [ "draft_refused", nil ], [ record.status, record.number ]

    post "#{BASE_PATH}/#{sandbox.session_id}/pull_request", params: { update: true, files: selection(preview!(sandbox), "README.md") }, as: :json

    assert_response :unprocessable_entity
    assert_equal "not_opened", JSON.parse(response.body)["code"]
    assert_equal [ "draft_refused", "create" ], [ record.reload.status, record.operation ]
    assert_empty enqueued_jobs

    post "#{BASE_PATH}/#{sandbox.session_id}/pull_request", params: { regular: true }, as: :json
    assert_response :accepted, response.body
    perform_enqueued_jobs
    assert_equal [ "published", 12, false, nil ], [ record.reload.status, record.number, record.draft, record.compare_url ]
  end

  test "a branch whose pull request failed to open keeps its compare link, and opening it again opens a draft" do
    sandbox = app_sandbox!
    stage!(sandbox)
    stub_github!(pulls_failure: { status: 502, body: { message: "Server Error" } })
    publish!(sandbox, preview_files: preview!(sandbox), paths: [ "README.md" ])
    perform_enqueued_jobs
    record = ActionAgent::DraftPullRequest.sole
    assert_equal [ "failed", "github_error", "d" * 40, nil ], [ record.status, record.error_code, record.head_commit, record.number ]
    assert_equal "https://github.com/acme/shop/compare/main...activeagent/gadgets?expand=1", record.compare_url

    post "#{BASE_PATH}/#{sandbox.session_id}/pull_request", params: { update: true, files: selection(preview!(sandbox), "README.md") }, as: :json
    assert_equal "not_opened", JSON.parse(response.body)["code"]

    @calls.clear
    stub_github!
    post "#{BASE_PATH}/#{sandbox.session_id}/pull_request", params: { open: true }, as: :json
    assert_response :accepted, response.body
    perform_enqueued_jobs

    record.reload
    assert_equal [ "published", "open_draft", 12, true, nil ], [ record.status, record.operation, record.number, record.draft, record.compare_url ]
    assert_equal %w[pulls], @calls.reject { |call| call[:method] == :get }.map { |call| call[:endpoint] }, "the branch is not pushed again"

    post "#{BASE_PATH}/#{sandbox.session_id}/pull_request", params: { open: true }, as: :json
    assert_equal "nothing_published", JSON.parse(response.body)["code"], "a branch with a pull request is not opened twice"
  end

  test "a draft is taken for refused only from GitHub's validation errors, never from a branch name in them" do
    sandbox = app_sandbox!
    stage!(sandbox)
    stub_github!(branch: "fix/draft-mode", pulls_failure: {
      status: 422,
      body: { message: "Validation Failed", errors: [ { resource: "PullRequest", code: "custom", message: "No commits between main and fix/draft-mode" } ] }
    })
    publish!(sandbox, preview_files: preview!(sandbox), paths: [ "README.md" ], branch: "fix/draft-mode")
    perform_enqueued_jobs

    record = ActionAgent::DraftPullRequest.sole
    assert_equal [ "failed", "github_error" ], [ record.status, record.error_code ]
    assert_match(/No commits between main and fix\/draft-mode/, record.error_message)

    ActionAgent::DraftPullRequest.delete_all
    stub_github!(draft_refused: { message: "Validation Failed", errors: [ { resource: "PullRequest", field: "draft", code: "invalid" } ] })
    publish!(sandbox, preview_files: preview!(sandbox), paths: [ "README.md" ])
    perform_enqueued_jobs
    assert_equal "draft_refused", ActionAgent::DraftPullRequest.sole.status
  end

  test "a second request for a record that is queued or publishing is refused, and enqueues nothing" do
    sandbox = app_sandbox!
    stage!(sandbox)
    stub_github!
    publish!(sandbox, preview_files: preview!(sandbox), paths: [ "README.md" ])
    perform_enqueued_jobs
    record = ActionAgent::DraftPullRequest.sole
    stage!(sandbox, readme: "# Shop v3\n")
    files = selection(preview!(sandbox), "README.md")

    post "#{BASE_PATH}/#{sandbox.session_id}/pull_request", params: { update: true, files: files, message: "First" }, as: :json
    assert_response :accepted
    post "#{BASE_PATH}/#{sandbox.session_id}/pull_request", params: { update: true, files: files, message: "Second" }, as: :json
    assert_response :conflict
    assert_equal [ "queued", "First" ], [ record.reload.status, record.commit_message ]

    record.update_columns(status: "publishing")
    post "#{BASE_PATH}/#{sandbox.session_id}/pull_request", params: { update: true, files: files }, as: :json
    assert_response :conflict
    assert_equal "publishing", record.reload.status
    assert_equal 1, enqueued_jobs.count { |job| job[:job] == ActionAgent::DraftPullRequestJob }
  end

  test "a publish that never finishes fails as stalled after STALL_AFTER, and the sandbox can publish again" do
    sandbox = app_sandbox!
    stage!(sandbox)
    preview = preview!(sandbox)
    publish!(sandbox, preview_files: preview, paths: [ "README.md" ])
    assert_response :accepted
    stalled = ActionAgent::DraftPullRequest.sole
    stalled.update_columns(status: "publishing")

    travel ActionAgent::DraftPullRequest::STALL_AFTER - 1.minute do
      publish!(sandbox, preview_files: preview, paths: [ "README.md" ], branch: "activeagent/other")
      assert_response :conflict
    end

    travel ActionAgent::DraftPullRequest::STALL_AFTER + 1.minute do
      get "#{BASE_PATH}/#{sandbox.session_id}/pull_request"
      pull_request = JSON.parse(response.body)["pull_request"]
      assert_equal [ "failed", "stalled" ], pull_request.values_at("status", "error_code")

      publish!(sandbox, preview_files: preview, paths: [ "README.md" ], branch: "activeagent/other")
      assert_response :accepted
    end

    ActionAgent::DraftPullRequestJob.perform_now(stalled.id)
    assert_equal [ "failed", "stalled" ], [ stalled.reload.status, stalled.error_code ], "the stalled publish's job no longer runs it"
    assert_not_requested :post, mint_url
  end

  test "the mock backend offers no publishing" do
    ActionAgent.sandbox_service = :mock
    sandbox = app_sandbox!

    get "#{BASE_PATH}/#{sandbox.session_id}/pull_request"
    assert_equal [ false, false ], JSON.parse(response.body)["publishing"].values_at("supported", "available")
    get "#{BASE_PATH}?sandbox_type=app_runtime"
    assert_equal false, JSON.parse(response.body)["pull_requests_supported"]
  end

  # Implements only the required verbs.
  class BareBackend
    def create_sandbox(_session) = { container_name: "bare" }
    def status(_handle) = { status: "running" }
    def terminate(_handle) = true
    def list_sandboxes = []
    def cleanup_expired = 0
  end

  # Lists changes, and reads files the way a backend written before read_file
  # took base: does.
  class NoBaseBackend < BareBackend
    def changed_files(_session) = { base_commit: BASE, files: [] }
    def read_file(_session, _path) = "".b
  end

  private

  # A ready checkout sandbox of REPO through a linked installation.
  def app_sandbox!(permissions: { contents: "write", pull_requests: "write", metadata: "read" }, account_id: nil, user_id: nil)
    link_installation!(repositories: [ repo_row(5, REPO) ], permissions: permissions, account_id: account_id) unless
      ActionAgent::GithubInstallation.exists?(installation_id: GithubAppTestHelper::INSTALLATION_ID)
    oauth_sandbox!(account_id: account_id, user_id: user_id).tap do |sandbox|
      assert sandbox.github_installation_id, "checked out through the installation"
    end
  end

  # A ready checkout sandbox of REPO, through whatever reaches it.
  def oauth_sandbox!(account_id: nil, user_id: nil)
    sandbox = ActionAgent::SandboxSession.new(sandbox_type: "app_runtime", repository: REPO, account_id: account_id, user_id: user_id)
    sandbox.save!
    sandbox.update_columns(status: ActionAgent::SandboxSession.statuses[:ready])
    sandbox
  end

  # An account-owned install whose signed-in user is a member of the
  # account. Returns [account, member].
  def multi_tenant!
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "User" # the dummy app has no Account
    ActionAgent.multi_tenant = true
    account = User.create!(email: "account@example.com", name: "Account", age: 30)
    member = User.create!(email: "member@example.com", name: "Member", age: 30)
    ActionAgent.current_account_resolver = ->(_controller) { account }
    ActionAgent.current_user_resolver = ->(_controller) { member }
    [ account, member ]
  end

  def stage!(sandbox, readme: "# Shop v2\n", working: {})
    StagedCheckoutBackend.stage_checkout(
      sandbox.session_id,
      base_commit: BASE,
      base: { "README.md" => "# Shop\n", "lib/old.rb" => "OLD = 1\n", ".github/workflows/ci.yml" => "on: [push]\n" },
      working: { "README.md" => readme, "app/models/gadget.rb" => "class Gadget; end\n", ".github/workflows/ci.yml" => "on: [push]\n" }
        .merge(working)
    )
  end

  def connect_claude_key!
    ActionAgent::ProviderKey.create!(provider: "claude_code", credential: CLAUDE_KEY)
  end

  def connect_oauth!(scopes:, account_id: nil, user_id: nil)
    ActionAgent::GithubConnection.create!(access_token: OAUTH_TOKEN, scopes: scopes, github_user_id: 42, login: "octocat",
      repositories: [ repo_row(5, REPO) ], account_id: account_id, user_id: user_id)
  end

  def preview!(sandbox, allowlist: nil)
    post "#{BASE_PATH}/#{sandbox.session_id}/pull_request/preview", params: { allowlist: allowlist }.compact, as: :json
    assert_response :success, response.body
    JSON.parse(response.body)["preview"]
  end

  def selection(preview, *paths)
    paths.map do |path|
      file = preview["files"].find { |entry| entry["path"] == path } or flunk "#{path} is not in the preview"
      { path: path, digest: file["digest"] }
    end
  end

  # Asks to publish +paths+ with the digests +preview_files+ reported, or
  # with a made-up digest for a file the preview refused (+forge+).
  def publish!(sandbox, preview_files:, paths:, branch: "activeagent/gadgets", allowlist: nil, forge: false)
    files = forge ? paths.map { |path| { path: path, digest: "0" * 64 } } : selection(preview_files, *paths)
    post "#{BASE_PATH}/#{sandbox.session_id}/pull_request",
      params: { title: "Add gadgets", branch: branch, files: files, allowlist: allowlist }.compact, as: :json
  end

  # Stubs every GitHub call a publish makes, recording each as
  # { method:, endpoint:, token:, body: } in @calls. +draft_refused+ is
  # true for GitHub's usual refusal of a draft, or the body to refuse it
  # with; +pulls_failure+ ({ status:, body: }) fails every POST /pulls.
  def stub_github!(token: WRITE_TOKEN, branch: "activeagent/gadgets", branch_head: nil, commit_sha: "d" * 40, draft_refused: false,
                   create_ref_status: 201, blob_status: 201, pulls_failure: nil)
    stub_mint(token: token) unless token == OAUTH_TOKEN
    api = "#{GithubAppTestHelper::API}/repos/#{REPO}"
    draft_refusal = draft_refused == true ? DRAFT_REFUSAL : draft_refused
    blobs = 0
    record = lambda do |method, endpoint, request|
      @calls << { method: method, endpoint: endpoint, token: bearer(request), body: request.body.present? ? JSON.parse(request.body) : nil }
    end

    stub_request(:get, "#{api}/git/ref/heads/main").to_return(status: 200, body: { object: { sha: BASE } }.to_json)
    stub_request(:get, "#{api}/git/ref/heads/#{branch}").to_return do |request|
      record.call(:get, "ref", request)
      branch_head ? { status: 200, body: { object: { sha: branch_head } }.to_json } : { status: 404, body: { message: "Not Found" }.to_json }
    end
    stub_request(:get, "#{api}/git/commits/#{BASE}").to_return(status: 200, body: { sha: BASE, tree: { sha: BASE_TREE } }.to_json)
    stub_request(:post, "#{api}/git/blobs").to_return do |request|
      record.call(:post, "blobs", request)
      next { status: blob_status, body: { message: "Resource not accessible by integration" }.to_json } unless blob_status == 201

      blobs += 1
      { status: 201, body: { sha: "blob-#{blobs}".ljust(40, "0") }.to_json }
    end
    stub_request(:post, "#{api}/git/trees").to_return do |request|
      record.call(:post, "trees", request)
      { status: 201, body: { sha: "a" * 40 }.to_json }
    end
    stub_request(:post, "#{api}/git/commits").to_return do |request|
      record.call(:post, "commits", request)
      { status: 201, body: { sha: commit_sha }.to_json }
    end
    stub_request(:post, "#{api}/git/refs").to_return do |request|
      record.call(:post, "refs", request)
      create_ref_status == 201 ? { status: 201, body: { ref: "refs/heads/x" }.to_json } : { status: 422, body: { message: "Reference already exists" }.to_json }
    end
    stub_request(:patch, "#{api}/git/refs/heads/#{branch}").to_return do |request|
      record.call(:patch, "refs", request)
      { status: 200, body: { ref: "refs/heads/#{branch}" }.to_json }
    end
    stub_request(:post, "#{api}/pulls").to_return do |request|
      record.call(:post, "pulls", request)
      draft = JSON.parse(request.body)["draft"]
      if pulls_failure
        { status: pulls_failure.fetch(:status), body: pulls_failure.fetch(:body).to_json }
      elsif draft && draft_refusal
        { status: 422, body: draft_refusal.to_json }
      else
        { status: 201, body: { number: 12, html_url: "https://github.com/#{REPO}/pull/12", state: "open", draft: draft }.to_json }
      end
    end
  end
end
