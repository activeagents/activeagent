# frozen_string_literal: true

require "test_helper"
require "open3"

# The install pull request of a project, read from a :local checkout that
# holds what a bootstrap would have written, and published to a stubbed
# GitHub: only the allowlisted paths and the files the project generates,
# never .github/ or a file holding one of the project's secrets; later boots
# check its branch out until it merges.
class ProjectInstallPullRequestTest < ActionDispatch::IntegrationTest
  OAUTH_TOKEN = "gho_#{'P' * 36}"
  REPO = "acme/shop"
  API = "https://api.github.com/repos/#{REPO}"
  BASE = "/activeagents/api/projects"
  SECRET = "sk_test_install s3cret-0123456789"
  BRANCH = ActionAgent::ProjectInstallPullRequest::DEFAULT_BRANCH

  def setup
    [ ActionAgent::DraftPullRequest, ActionAgent::Project, ActionAgent::ProjectSecret, ActionAgent::EvaluationScenario,
      ActionAgent::Evaluation, ActionAgent::Agent, ActionAgent::SandboxSession, ActionAgent::GithubConnection ].each(&:delete_all)
    @tmp = Pathname(Dir.mktmpdir("project-install-pr")).realpath
    @saved = {
      enabled: ActionAgent.instance_variable_get(:@local_sandboxes_enabled),
      root: ActionAgent.instance_variable_get(:@local_sandbox_root),
      service: ActionAgent.sandbox_service
    }
    ActionAgent.local_sandboxes_enabled = true
    ActionAgent.local_sandbox_root = @tmp.join("sandboxes").to_s
    ActionAgent.sandbox_service = :local
    ActionAgent::GithubConnection.create!(
      access_token: OAUTH_TOKEN, scopes: "repo", github_user_id: 42, login: "octocat",
      repositories: [ ActionAgent::GithubClient.slice_repository({ "id" => 5, "full_name" => REPO, "default_branch" => "main" }) ]
    )
    @project = ActionAgent::Project.create!(name: "Shop", repository: REPO, install_state: "bootstrapped", status: "ready",
      settings: { "preflight" => { "status" => "bootstrap", "engine" => false, "activeagent" => nil },
                  "local_boot_confirmed_at" => Time.current.iso8601,
                  "schema_tools" => [ { "model" => "Post", "filterable" => [ "published" ], "returns" => [ "title" ] } ] })
    @project.assign_secret(name: "SHOP_API_KEY", value: SECRET).save!
    @project.ensure_app_assistant!
    @project.evaluation.scenarios.create!(key: "posts_1", group: "Posts", prompt: "How many posts are published?",
      expectations: { "tools" => [ "count_posts" ] }, notes: "The seed data has two.", position: 0)
    @project.evaluation.scenarios.create!(key: "posts_2", group: "Posts", prompt: "Disabled", enabled: false, position: 1)
    @project.evaluation.scenarios.create!(key: "hello", prompt: "Say hello", expectations: { "contains" => [ "hello" ] }, position: 2)
    @sandbox = live_sandbox!
    @base = bootstrapped_checkout!
  end

  def teardown
    ActionAgent.instance_variable_set(:@local_sandboxes_enabled, @saved[:enabled])
    ActionAgent.instance_variable_set(:@local_sandbox_root, @saved[:root])
    ActionAgent.sandbox_service = @saved[:service]
    ActionAgent.permission_checker = nil
    FileUtils.rm_rf(@tmp)
  end

  test "the preview offers only the allowlisted paths and the generated files, with their exact diffs" do
    post "#{BASE}/#{@project.id}/install_pull_request/preview", as: :json

    assert_response :success, response.body
    files = JSON.parse(response.body).dig("preview", "files").index_by { |file| file["path"] }
    publishable = files.reject { |_path, file| file["refusal"] }.keys.sort
    assert_equal [
      ".activeagents/evals/shop.yml", ".activeagents/sandbox.yml", "Gemfile", "Gemfile.lock", "app/agent_tools/post_tools.rb",
      "app/agents/application_agent.rb", "config/active_agent.yml", "config/routes.rb",
      "db/migrate/20260101000000_create_active_agent_dashboard_tables.rb", "db/migrate/20260101000001_add_agent_releases.rb",
      "db/schema.rb"
    ], publishable
    assert_equal "excluded", files.dig(".github/workflows/ci.yml", "refusal")
    %w[.env config/database.yml app/agent_tools/user_tools.rb db/migrate/20260101000002_create_widgets.rb].each do |path|
      assert_equal "not_allowed", files.dig(path, "refusal"), path
    end
    assert_equal "secret", files.dig("config/initializers/action_agent.rb", "refusal")
    assert_match(/^\+gem "actionagent"/, files.dig("Gemfile", "diff"))
    assert_equal BRANCH, JSON.parse(response.body).dig("preview", "suggested_branch")
    assert_not_includes response.body, SECRET
  end

  test "sandbox.yml holds the setup and the secrets' names, never their values" do
    config = ActionAgent::ProjectInstallPullRequest.new(@project).generated_files(@sandbox)[".activeagents/sandbox.yml"]

    data = YAML.safe_load(config)
    assert_equal [ "bundle install", "bin/rails db:prepare" ], data["setup"]
    assert_equal [ "SHOP_API_KEY" ], data["secrets"]
    assert_not_includes config, SECRET
  end

  test "the evaluation suite loads with ActiveAgent::Evals::Suite.load and yields the enabled scenarios" do
    suite = ActionAgent::ProjectInstallPullRequest.new(@project).generated_files(@sandbox)[".activeagents/evals/shop.yml"]
    path = @tmp.join("shop.yml").tap { |file| file.write(suite) }

    loaded = ActiveAgent::Evals::Suite.load(path.to_s)

    assert_equal "shop", loaded.name
    assert_equal %w[posts_1 hello], loaded.all_scenarios.map(&:key)
    posts = loaded.find("posts_1")
    assert_equal [ "Posts", "How many posts are published?", [ "count_posts" ], "The seed data has two." ],
      [ posts.group, posts.prompt, posts.expected_tools, posts.notes ]
    assert_equal [ "hello" ], loaded.find("hello").expected_patterns
  end

  test "publishing opens a draft with the chosen files, and later boots check its branch out without installing again" do
    stub_github!
    preview = preview!

    perform_enqueued_jobs do
      post "#{BASE}/#{@project.id}/install_pull_request",
        params: { title: "Install ActiveAgent", branch: BRANCH, files: chosen(preview, "Gemfile", ".activeagents/sandbox.yml") }, as: :json
    end

    assert_response :accepted, response.body
    record = @project.reload.install_pull_request
    assert_equal [ "published", 3, "open" ], [ record.status, record.number, record.state ], record.error_message
    assert_equal %w[.activeagents/sandbox.yml Gemfile], record.files.map { |file| file["path"] }.sort
    assert_requested(:post, "#{API}/git/trees") do |request|
      JSON.parse(request.body)["tree"].map { |entry| entry["path"] }.sort == %w[.activeagents/sandbox.yml Gemfile]
    end
    get "#{BASE}/#{@project.id}"
    assert_equal 3, JSON.parse(response.body).dig("project", "install_pull_request", "number")

    assert_equal BRANCH, @project.checkout_ref
    @sandbox.update_columns(expires_at: 1.minute.ago)
    next_sandbox = @project.reload.ensure_sandbox!
    spec = @project.boot_spec(next_sandbox)
    assert_equal BRANCH, next_sandbox.repository_ref
    assert_equal "always", spec.apply
    assert_empty spec.steps.map { |step| step["name"] } & ActionAgent::SandboxBootSpec::INSTALL_STEPS,
      "the branch bundles the engine already"
    assert_equal %w[bundle_install javascript_build css_build tailwindcss_build db_prepare schema_tools], spec.steps.map { |step| step["name"] }
  end

  test "a file holding a project secret, or under .github/, is refused when it is chosen" do
    stub_github!
    preview = preview!
    digests = preview["files"].to_h { |file| [ file["path"], file["digest"].to_s ] }

    [ "config/initializers/action_agent.rb", ".github/workflows/ci.yml" ].each do |path|
      post "#{BASE}/#{@project.id}/install_pull_request",
        params: { title: "Install", branch: BRANCH, files: [ { path: path, digest: digests[path].presence || "x" } ] }, as: :json

      assert_response :unprocessable_entity
      assert_includes %w[secret not_publishable], JSON.parse(response.body)["code"], path
    end
    assert_nil @project.reload.install_pull_request
    assert_not_requested :post, "#{API}/git/blobs"
  end

  test "publishing needs :publish_pull_request" do
    ActionAgent.permission_checker = ->(_user, action, _subject) { action != :publish_pull_request }
    preview = preview!

    post "#{BASE}/#{@project.id}/install_pull_request", params: { title: "Install", files: chosen(preview, "Gemfile") }, as: :json

    assert_response :forbidden
    assert_nil @project.reload.install_pull_request
  end

  test "an update from a later sandbox of the branch goes on top of the branch as that sandbox checked it out" do
    stub_github!
    preview = preview!
    perform_enqueued_jobs do
      post "#{BASE}/#{@project.id}/install_pull_request", params: { title: "Install", branch: BRANCH, files: chosen(preview, "Gemfile") },
        as: :json
    end
    opened = @project.reload.install_pull_request

    @sandbox.update_columns(expires_at: 1.minute.ago)
    @sandbox = live_sandbox!(ref: BRANCH)
    head = checkout!("Gemfile" => "source \"https://rubygems.org\"\ngem \"rails\"\ngem \"actionagent\"\n", "Gemfile.lock" => "GEM\n")
    @checkout.join("Gemfile.lock").write("GEM\n  specs:\n    actionagent (1.9.0)\n")
    stub_request(:get, "#{API}/git/ref/heads/#{BRANCH}").to_return(status: 200, body: { object: { sha: head } }.to_json)
    stub_request(:get, "#{API}/git/commits/#{head}").to_return(status: 200, body: { tree: { sha: "d" * 40 } }.to_json)
    stub_request(:patch, "#{API}/git/refs/heads/activeagent/install-engine").to_return(status: 200, body: {}.to_json)
    preview = preview!

    perform_enqueued_jobs do
      post "#{BASE}/#{@project.id}/install_pull_request", params: { update: true, message: "Lock the engine", files: chosen(preview, "Gemfile.lock") },
        as: :json
    end

    assert_response :accepted, response.body
    update = @project.reload.install_pull_request
    assert_not_equal opened.id, update.id
    assert_equal [ "published", 3, head ], [ update.status, update.number, update.base_commit ], update.error_message
    assert_requested(:post, "#{API}/git/commits") { |request| JSON.parse(request.body)["parents"] == [ head ] }
    assert_requested(:patch, "#{API}/git/refs/heads/activeagent/install-engine") { |request| JSON.parse(request.body)["force"] == false }
  end

  test "once GitHub reports the pull request merged, the project is installed and boots its own branch" do
    stub_github!
    preview = preview!
    perform_enqueued_jobs do
      post "#{BASE}/#{@project.id}/install_pull_request", params: { title: "Install", branch: BRANCH, files: chosen(preview, "Gemfile") },
        as: :json
    end
    @project.reload.install_pull_request.update_columns(last_checked_at: 2.minutes.ago)
    stub_request(:get, "#{API}/pulls/3").to_return(status: 200, body: { number: 3, state: "closed", merged: true, draft: false }.to_json)

    get "#{BASE}/#{@project.id}/install_pull_request"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [ "merged", "installed" ], [ body.dig("pull_request", "state"), body.dig("project", "install_state") ]
    assert_nil @project.reload.checkout_ref, "boots the repository's own default branch again"
  end

  test "a branch GitHub would not open as a draft is opened as a regular pull request on request" do
    stub_github!
    stub_request(:post, "#{API}/pulls").to_return(
      { status: 422, body: { message: "Validation Failed", errors: [ { resource: "PullRequest", field: "draft", code: "invalid" } ] }.to_json },
      { status: 201, body: { number: 4, html_url: "https://github.com/#{REPO}/pull/4", state: "open", draft: false }.to_json }
    )
    preview = preview!
    perform_enqueued_jobs do
      post "#{BASE}/#{@project.id}/install_pull_request", params: { title: "Install", branch: BRANCH, files: chosen(preview, "Gemfile") },
        as: :json
    end
    assert_equal "draft_refused", @project.reload.install_pull_request.status
    assert_equal BRANCH, @project.checkout_ref, "the published branch is booted while it waits for its pull request"

    perform_enqueued_jobs { post "#{BASE}/#{@project.id}/install_pull_request", params: { regular: true }, as: :json }

    assert_response :accepted, response.body
    record = @project.reload.install_pull_request
    assert_equal [ "published", 4, false ], [ record.status, record.number, record.draft ], record.error_message
  end

  test "a request while the sandbox is not running boots one and answers 202" do
    @sandbox.update_columns(expires_at: 1.minute.ago)

    post "#{BASE}/#{@project.id}/install_pull_request/preview", as: :json

    assert_response :accepted
    assert_equal "sandbox_booting", JSON.parse(response.body)["code"]
    assert_not_equal @sandbox.id, @project.reload.current_sandbox_session_id
  end

  test "the migration pattern matches each engine migration by its whole name only" do
    pattern = ActionAgent::ProjectInstallPullRequest.new(@project).allowlist.grep(Regexp).sole

    assert_match pattern, "db/migrate/20260101000000_add_agent_releases.rb"
    assert_match pattern, "db/migrate/20260101000000_create_active_agent_projects.rb"
    assert_no_match pattern, "db/migrate/20260101000000_add_agent_releases_backfill.rb"
    assert_no_match pattern, "db/migrate/x_add_agent_releases.rb"
    assert_no_match pattern, "db/migrate/20260101000000_create_widgets.rb"
  end

  private

  def live_sandbox!(ref: nil)
    sandbox = ActionAgent::SandboxSession.create!(sandbox_type: "app_runtime", repository: REPO, repository_ref: ref)
    sandbox.update_columns(status: ActionAgent::SandboxSession.statuses[:ready], project_id: @project.id)
    @project.update!(current_sandbox_session: sandbox)
    @checkout = @tmp.join("sandboxes", sandbox.session_id, "app")
    sandbox
  end

  # A checkout of a repository without the engine, then what a bootstrap
  # writes into it.
  def bootstrapped_checkout!
    base = checkout!(
      "Gemfile" => "source \"https://rubygems.org\"\ngem \"rails\"\n",
      "Gemfile.lock" => "GEM\n  specs:\n    rails (8.0.1)\n",
      "config/routes.rb" => "Rails.application.routes.draw do\nend\n",
      "config/database.yml" => "development:\n  adapter: sqlite3\n",
      ".github/workflows/ci.yml" => "name: CI\n"
    )
    {
      "Gemfile" => "source \"https://rubygems.org\"\ngem \"rails\"\ngem \"actionagent\", \"~> 1.9.0\"\n",
      "Gemfile.lock" => "GEM\n  specs:\n    actionagent (1.9.0)\n    rails (8.0.1)\n",
      "config/routes.rb" => "Rails.application.routes.draw do\n  mount ActionAgent::Engine => \"/activeagents\"\nend\n",
      "config/initializers/action_agent.rb" => "ActionAgent.configure { |config| config.api_key = \"#{SECRET}\" }\n",
      "config/active_agent.yml" => "development:\n  openai:\n    service: OpenAI\n",
      "app/agents/application_agent.rb" => "class ApplicationAgent < ActiveAgent::Base\nend\n",
      "app/agent_tools/post_tools.rb" => "class PostTools < ActiveAgent::SchemaTools\n  model Post\nend\n",
      "app/agent_tools/user_tools.rb" => "class UserTools < ActiveAgent::SchemaTools\n  model User\nend\n",
      "db/migrate/20260101000000_create_active_agent_dashboard_tables.rb" => "# dashboard tables\n",
      "db/migrate/20260101000001_add_agent_releases.rb" => "# releases\n",
      "db/migrate/20260101000002_create_widgets.rb" => "# not the engine's\n",
      "db/schema.rb" => "# schema\n",
      ".env" => "SHOP_API_KEY=#{SECRET}\n",
      "config/database.yml" => "development:\n  adapter: sqlite3\n  database: storage/sandbox.sqlite3\n",
      ".github/workflows/ci.yml" => "name: CI\non: push\n"
    }.each { |path, content| @checkout.join(path).tap { |file| file.dirname.mkpath }.write(content) }
    base
  end

  def checkout!(files)
    @checkout.mkpath
    git("init", "-q")
    files.each { |path, content| @checkout.join(path).tap { |file| file.dirname.mkpath }.write(content) }
    git("add", "--all")
    git("commit", "-q", "-m", "Initial")
    commit = git("rev-parse", "HEAD").strip
    @checkout.dirname.join("state.json").write(JSON.generate("checkout_commit" => commit))
    commit
  end

  def git(*args)
    env = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1" }
    argv = [ "git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", *args ]
    output, status = Open3.capture2e(env, *argv, chdir: @checkout.to_s)
    assert status.success?, "git #{args.join(' ')} failed: #{output}"
    output
  end

  def preview!
    post "#{BASE}/#{@project.id}/install_pull_request/preview", as: :json
    assert_response :success, response.body
    JSON.parse(response.body)["preview"]
  end

  def chosen(preview, *paths)
    preview["files"].select { |file| paths.include?(file["path"]) }.map { |file| { path: file["path"], digest: file["digest"] } }
  end

  def stub_github!
    stub_request(:get, "#{API}/git/ref/heads/main").to_return(status: 200, body: { object: { sha: @base } }.to_json)
    stub_request(:get, "#{API}/git/ref/heads/#{BRANCH}").to_return(status: 404, body: { message: "Not Found" }.to_json)
    stub_request(:get, "#{API}/git/commits/#{@base}").to_return(status: 200, body: { tree: { sha: "c" * 40 } }.to_json)
    stub_request(:post, "#{API}/git/blobs").to_return(status: 201, body: { sha: "1" * 40 }.to_json)
    stub_request(:post, "#{API}/git/trees").to_return(status: 201, body: { sha: "2" * 40 }.to_json)
    stub_request(:post, "#{API}/git/commits").to_return(status: 201, body: { sha: "3" * 40 }.to_json)
    stub_request(:post, "#{API}/git/refs").to_return(status: 201, body: {}.to_json)
    stub_request(:post, "#{API}/pulls")
      .to_return(status: 201, body: { number: 3, html_url: "https://github.com/#{REPO}/pull/3", state: "open", draft: true }.to_json)
  end
end
