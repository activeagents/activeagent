# frozen_string_literal: true

require "test_helper"

# An account model for the multi-tenant cases, whose ids are set apart from
# the users' so a lookup by the wrong owner column would find the wrong row.
class ProjectTestAccount < ActiveRecord::Base
  def self.ensure_table!
    return if connection.table_exists?(:project_test_accounts)

    connection.create_table(:project_test_accounts) { |t| t.string :name }
  end
end
ProjectTestAccount.ensure_table!

# Projects over the JSON API: the capabilities checklist, the pick-time
# preflight and secret discovery read through GitHub's contents API, creating
# a project with its secrets, booting it through a backend that takes boot
# specs, following the boot, choosing the agent to evaluate and running the
# project's evaluation against its sandbox.
class ProjectsApiTest < ActionDispatch::IntegrationTest
  GITHUB_TOKEN = "gho_projectsApiToken0123456789"
  RUNTIME_URL = "http://127.0.0.1:4200/activeagents/mcp"
  RUNTIME_TOKEN = "aa_runtime_projects_s3cret"
  CHAT_URL = "https://api.openai.com/v1/chat/completions"
  # Characters URL encoding and Base64 both change.
  SECRET = "sk_test_pr0ject s3cret/value+0123"
  BASE = "/activeagents/api/projects"

  # Takes a boot spec and implements the boot verbs, recording what it was
  # asked. The orchestrator builds a backend per call, so state is on the
  # class.
  class ProjectBackend
    class << self
      attr_accessor :calls, :create_error, :boot_state, :log_pages

      def reset!
        self.calls = []
        self.create_error = nil
        self.boot_state = nil
        self.log_pages = {}
      end
    end

    def create_sandbox(session, boot_config: nil)
      self.class.calls << [ :create, session.session_id, boot_config ]
      raise self.class.create_error if self.class.create_error

      created(session)
    end

    def resume_boot(session, from:, boot_config: nil)
      self.class.calls << [ :resume_boot, session.session_id, from, boot_config ]
      created(session)
    end

    def boot_status(_session) = self.class.boot_state

    def boot_log(_session, step:, offset:, secrets:, limit: 65_536)
      text = self.class.log_pages[step] or return nil
      page = text.byteslice(offset, limit).to_s
      { step: step, offset: offset, next_offset: offset + page.bytesize, size: text.bytesize,
        eof: offset + page.bytesize >= text.bytesize, text: ActionAgent::SecretScrubber.scrub(page, secrets) }
    end

    def handle_for(session) = "project-#{session.session_id}"

    def terminate(handle)
      self.class.calls << [ :terminate, handle ]
      true
    end

    def status(_handle) = { status: "running" }
    def list_sandboxes = []
    def cleanup_expired = 0

    private

    def created(session)
      { container_name: handle_for(session), url: "http://127.0.0.1:4200", mcp_url: RUNTIME_URL, mcp_token: RUNTIME_TOKEN }
    end
  end

  # The :local backend as far as the orchestrator can tell, booting nothing.
  class LocalProjectBackend < ActionAgent::LocalSandboxBackend
    def create_sandbox(session, instance_tier: nil, boot_config: nil)
      ProjectBackend.new.create_sandbox(session, boot_config: boot_config)
    end
  end

  # A backend that cannot take a boot spec.
  class PlainBackend
    def create_sandbox(session) = { container_name: "plain-#{session.session_id}", url: "http://127.0.0.1:9" }
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
    ActionAgent::GithubConnection.delete_all
    ActionAgent::ProviderKey.delete_all
    ProjectBackend.reset!
    WebMock::RequestRegistry.instance.reset!

    @original_backends = ActionAgent.sandbox_backends
    @original_service = ActionAgent.sandbox_service
    ActionAgent.sandbox_backends = {
      "project_test" => ProjectBackend.name, "local_project" => LocalProjectBackend.name, "plain" => PlainBackend.name
    }
    ActionAgent.sandbox_service = "project_test"
    ActionAgent.github_client_id = "client-id"
    ActionAgent.github_client_secret = "client-secret"
    @connection = ActionAgent::GithubConnection.create!(
      access_token: GITHUB_TOKEN, github_user_id: 42, login: "octocat",
      repositories: [ repo_row("acme/shop") ]
    )
  end

  def teardown
    ActionAgent.sandbox_backends = @original_backends
    ActionAgent.sandbox_service = @original_service
    ActionAgent.github_client_id = nil
    ActionAgent.github_client_secret = nil
    ActionAgent.permission_checker = nil
    ActionAgent.quota_checker = nil
    ActionAgent.usage_recorder = nil
    ActionAgent.provider_credentials_resolver = nil
    ActionAgent.multi_tenant = false
    ActionAgent.account_class = nil
    ActionAgent.user_class = nil
    ActionAgent.current_user_resolver = nil
    ActionAgent.current_account_resolver = nil
    ActionAgent.execution_enabled = true
  end

  # --- capabilities -------------------------------------------------------

  test "capabilities report the backend, GitHub with its exact callback URL, credentials and code runners" do
    get "#{BASE}/capabilities"

    assert_response :success
    body = JSON.parse(response.body)
    assert body["ready"], body["items"].inspect
    assert_equal "project_test", body["backend"]
    assert_equal "oauth", body.dig("github", "mode")
    assert_equal "http://www.example.com/activeagents/api/github_connection/callback", body.dig("github", "callback_url")
    assert_equal "https://github.com/settings/connections/applications/client-id", body.dig("github", "access_settings_url")
    assert_equal false, body.dig("browser", "available")
    assert_equal [], body["code_runners"]
    items = body["items"].index_by { |item| item["key"] }
    assert_equal %w[boot_spec browser code_runners execution github github_connection model_credentials sandbox_backend],
      items.keys.sort
    assert_equal [ false, false ], items["browser"].values_at("ok", "blocking")
    assert body.dig("default_model", "provider").present?
  end

  test "a failing blocking item names the line that fixes it, and creating a project is refused" do
    ActionAgent.github_client_id = nil
    ActionAgent.sandbox_service = "plain"
    skip "GITHUB_CLIENT_ID is set in this environment" if ENV["GITHUB_CLIENT_ID"].present?

    get "#{BASE}/capabilities"

    body = JSON.parse(response.body)
    assert_equal false, body["ready"]
    items = body["items"].index_by { |item| item["key"] }
    assert_equal false, items.dig("boot_spec", "ok")
    assert_equal "Use a sandbox backend whose create_sandbox accepts boot_config:", items.dig("boot_spec", "fix")
    assert_match(/callback URL http:\/\/www\.example\.com\/activeagents\/api\/github_connection\/callback/, items.dig("github", "fix"))

    post BASE, params: { repository: "acme/shop" }, as: :json

    assert_response :unprocessable_entity
    assert_equal "capabilities", JSON.parse(response.body)["code"]
    assert_equal 0, ActionAgent::Project.count
  end

  test "the mock backend is refused outside the test environment" do
    ActionAgent.sandbox_service = :mock
    production = ActiveSupport::EnvironmentInquirer.new("production")
    capabilities = ActionAgent::ProjectCapabilities.new(owner: nil, github_connected: true, base_url: "https://dash.example/aa",
      environment: production).call

    backend = capabilities[:items].find { |item| item[:key] == "sandbox_backend" }
    assert_equal false, capabilities[:ready]
    assert_equal [ false, true ], backend.values_at(:ok, :blocking)
    assert_equal "config.sandbox_service = :local  # config/initializers/action_agent.rb, or a backend you registered", backend[:fix]

    in_test = ActionAgent::ProjectCapabilities.new(owner: nil, github_connected: true, base_url: "https://dash.example/aa").call
    assert in_test[:items].find { |item| item[:key] == "sandbox_backend" }[:ok], "the test environment may use the mock"

    original = ActionAgent::ProjectCapabilities.method(:new)
    ActionAgent::ProjectCapabilities.stub(:new, ->(**options) { original.call(**options, environment: production) }) do
      post BASE, params: { repository: "acme/shop" }, as: :json
    end
    assert_response :unprocessable_entity
    assert_equal [ "sandbox_backend" ], JSON.parse(response.body)["items"].map { |item| item["key"] }
  end

  # --- preflight and discovery ---------------------------------------------

  test "preflight reads the repository through the contents API and reports a bootstrap" do
    stub_contents("acme/shop", "Gemfile.lock" => rails_lock, "config/application.rb" => "# app\n",
      "config/database.yml" => "default: &default\n  adapter: <%= 'postgresql' %>\n  adapter: postgresql\n",
      "Gemfile" => "gem \"rails\"\ngem \"sidekiq\"\n")

    get "#{BASE}/preflight", params: { repository: "acme/shop" }

    assert_response :success, response.body
    body = JSON.parse(response.body)
    assert_equal "acme/shop", body.dig("repository", "full_name")
    assert_equal true, body.dig("repository", "selected")
    preflight = body["preflight"]
    assert_equal "bootstrap", preflight["status"]
    assert_equal "Supported: installs the engine in the sandbox", preflight["summary"]
    assert_equal [ "3.3.6", "Gemfile.lock", "8.0.1" ], preflight.values_at("ruby", "ruby_source", "railties")
    assert_equal [ "postgresql" ], preflight["database_adapters"]
    assert_equal [ "Redis (for Sidekiq)" ], preflight["services"]
    assert_equal commit_for("acme/shop", "main"), preflight["commit"]
    assert_requested(:get, "https://api.github.com/repos/acme/shop/contents/Gemfile.lock?ref=#{commit_for("acme/shop", "main")}",
      headers: { "Authorization" => "Bearer #{GITHUB_TOKEN}" })
  end

  test "a repository past the listing's cap is found by owner/name, and one GitHub cannot find answers 404" do
    stub_request(:get, "https://api.github.com/repos/acme/billing")
      .to_return(status: 200, body: { id: 9, full_name: "acme/billing", private: true, default_branch: "trunk" }.to_json)
    stub_contents("acme/billing", "Gemfile.lock" => rails_lock(gems: [ "actionagent (1.9.0)", "activeagent (1.9.0)" ]),
      "config/application.rb" => "# app\n", ref: "trunk")
    stub_request(:get, "https://api.github.com/repos/acme/missing").to_return(status: 404, body: { message: "Not Found" }.to_json)

    get "#{BASE}/preflight", params: { repository: "acme/billing" }

    body = JSON.parse(response.body)
    assert_equal [ "acme/billing", false ], body["repository"].values_at("full_name", "selected")
    assert_equal [ "supported", "Supported", true ], body["preflight"].values_at("status", "summary", "engine")

    get "#{BASE}/preflight", params: { repository: "acme/missing" }
    assert_response :not_found
    assert_equal "repository_not_found", JSON.parse(response.body)["code"]

    get "#{BASE}/preflight", params: { repository: "not a name" }
    assert_response :bad_request
  end

  test "reading a repository outside the selection needs :manage_github, and GitHub is not asked without it" do
    stub_request(:get, "https://api.github.com/repos/someone/private-app")
      .to_return(status: 200, body: { id: 7, full_name: "someone/private-app", private: true, default_branch: "main" }.to_json)
    stub_contents("someone/private-app", "Gemfile.lock" => rails_lock, "config/application.rb" => "# app\n",
      ".env.example" => "INTERNAL_PAYMENTS_TOKEN=\n")
    stub_tree("someone/private-app", "main", [ ".env.example" ])
    stub_supported_repository
    stub_tree("acme/shop", "main", [])
    asked = []
    ActionAgent.permission_checker = lambda do |_user, action, subject|
      asked << [ action, subject.class.name ]
      false
    end

    %w[preflight discover_secrets].each do |endpoint|
      get "#{BASE}/#{endpoint}", params: { repository: "someone/private-app" }

      assert_response :forbidden, endpoint
      body = JSON.parse(response.body)
      assert_equal [ "forbidden", "manage_github" ], body.values_at("code", "permission")
      assert_not_includes response.body, "INTERNAL_PAYMENTS_TOKEN"
    end
    assert_not_requested(:get, %r{\Ahttps://api\.github\.com/repos/someone/private-app})
    assert_equal [ [ :manage_github, "ActionAgent::GithubConnection" ] ], asked.uniq

    get "#{BASE}/preflight", params: { repository: "acme/shop" }
    assert_response :success, "the selection is every member's to read"
    get "#{BASE}/discover_secrets", params: { repository: "acme/shop" }
    assert_response :success

    ActionAgent.permission_checker = ->(_user, action, _subject) { action == :manage_github }
    get "#{BASE}/discover_secrets", params: { repository: "someone/private-app" }
    assert_response :success
    assert_equal [ "INTERNAL_PAYMENTS_TOKEN" ], JSON.parse(response.body)["variables"].map { |variable| variable["name"] }
  end

  test "a revoked GitHub token asks for GitHub to be reconnected" do
    stub_request(:get, %r{\Ahttps://api\.github\.com/repos/acme/shop/}).to_return(status: 401, body: "{}")

    get "#{BASE}/preflight", params: { repository: "acme/shop" }

    assert_response :unprocessable_entity
    assert_equal true, JSON.parse(response.body)["reconnect_required"]
  end

  test "secret discovery returns the same names for the same ref, from env files, sandbox.yml and ENV call sites" do
    stub_contents("acme/shop",
      ".env.example" => "STRIPE_SECRET_KEY=sk_test_xxx\nexport OPENAI_API_KEY=\n# COMMENTED=1\nRAILS_ENV=development\n",
      ".activeagents/sandbox.yml" => { "secrets" => { "MAILER_PASSWORD" => "SMTP password for the sandbox" } }.to_yaml,
      "config/initializers/stripe.rb" => "Stripe.api_key = ENV.fetch(\"STRIPE_SECRET_KEY\")\nX = ENV[\"OPTIONAL_FLAG\"]\n",
      "config/storage.yml" => "s3:\n  secret: <%= ENV.fetch('AWS_SECRET', 'none') %>\n  path: <%= ENV['PATH'] %>\n")
    stub_tree("acme/shop", "main", [ ".env.example", ".activeagents/sandbox.yml", "config/initializers/stripe.rb", "config/storage.yml",
                                     "app/models/user.rb", "README.md" ])

    first = discover("acme/shop")
    second = discover("acme/shop")

    assert_equal first, second
    names = first["variables"].map { |variable| variable["name"] }
    assert_equal %w[AWS_SECRET MAILER_PASSWORD OPENAI_API_KEY OPTIONAL_FLAG STRIPE_SECRET_KEY], names
    stripe = first["variables"].find { |variable| variable["name"] == "STRIPE_SECRET_KEY" }
    assert_equal [ true, [ ".env.example:1", "config/initializers/stripe.rb:1" ] ], stripe.values_at("required", "sources")
    mailer = first["variables"].find { |variable| variable["name"] == "MAILER_PASSWORD" }
    assert_equal [ true, "SMTP password for the sandbox" ], mailer.values_at("required", "description")
    assert_equal false, first["variables"].find { |variable| variable["name"] == "AWS_SECRET" }["required"]
    assert_equal "openai", first["variables"].find { |variable| variable["name"] == "OPENAI_API_KEY" }["organization_key"]
    assert_equal %w[config/initializers/stripe.rb config/storage.yml], first["scanned"]
    assert_not_requested(:post, /api\.(openai|anthropic)\.com/)
    # The commit does not list it.
    assert_not_requested(:get, %r{/contents/\.env\.sample})
  end

  test "a repository is read once per commit: checking it again costs one GitHub call until the ref moves" do
    lock = rails_lock
    stub_contents("acme/shop", "Gemfile.lock" => lock, "config/application.rb" => "# app\n", ".env.example" => "STRIPE_SECRET_KEY=\n")
    stub_tree("acme/shop", "main", [ ".env.example" ])
    pushed = "f" * 40

    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      2.times { get "#{BASE}/preflight", params: { repository: "acme/shop" } }
      2.times { discover("acme/shop") }
      post BASE, params: { repository: "acme/shop" }, as: :json
      assert_response :created, response.body

      assert_requested(:get, "https://api.github.com/repos/acme/shop/commits", query: hash_including("sha" => "main"), times: 5)
      assert_requested(:get, %r{/contents/Gemfile\.lock\?}, times: 1)
      assert_requested(:get, %r{/contents/\.env\.example\?}, times: 1)
      assert_requested(:get, %r{/git/trees/}, times: 1)

      stub_contents("acme/shop", commit: pushed, "Gemfile.lock" => rails_lock(railties: "7.1.3"), "config/application.rb" => "# app\n")
      get "#{BASE}/preflight", params: { repository: "acme/shop" }

      assert_equal [ "unsupported", pushed ], JSON.parse(response.body)["preflight"].values_at("status", "commit")
      assert_requested(:get, %r{/contents/Gemfile\.lock\?}, times: 2)
    end
  end

  test "a ref that names no commit is unsupported, and discovery answers 404" do
    stub_request(:get, "https://api.github.com/repos/acme/shop/commits").with(query: hash_including("sha" => "gone"))
      .to_return(status: 404, body: { message: "No commit found for SHA: gone" }.to_json)
    # What GitHub answers for a repository with no commits at all.
    stub_request(:get, "https://api.github.com/repos/acme/shop/commits").with(query: hash_including("sha" => "main"))
      .to_return(status: 409, body: { message: "Git Repository is empty." }.to_json)

    %w[gone main].each do |ref|
      get "#{BASE}/preflight", params: { repository: "acme/shop", ref: ref }

      assert_response :success
      assert_equal [ "unsupported", "acme/shop has no commit at #{ref}" ],
        JSON.parse(response.body)["preflight"].values_at("status", "summary")
    end

    get "#{BASE}/discover_secrets", params: { repository: "acme/shop", ref: "gone" }
    assert_response :not_found
    assert_equal [ "not_found", "acme/shop has no commit at gone" ], JSON.parse(response.body).values_at("code", "error")
    assert_not_requested(:get, %r{/contents/|/git/trees/})
  end

  # --- creating -------------------------------------------------------------

  test "creating a project stores its secrets encrypted, answers with names only and gives it an App assistant" do
    usage = []
    ActionAgent.usage_recorder = ->(_owner, kind) { usage << kind }
    stub_supported_repository

    post BASE, params: { repository: "acme/shop", name: "Shop", secrets: [ { name: "STRIPE_SECRET_KEY", value: SECRET } ] }, as: :json

    assert_response :created, response.body
    assert_no_secret_in(response.body)
    body = JSON.parse(response.body)
    project = ActionAgent::Project.sole
    assert_equal [ "Shop", "acme/shop", "detected", "draft" ], body["project"].values_at("name", "repository", "install_state", "status")
    assert_equal [ "STRIPE_SECRET_KEY" ], body["secrets"].map { |secret| secret["name"] }
    assert_equal [ "entered" ], body["secrets"].map { |secret| secret["source"] }
    secret = project.secrets.sole
    assert_equal SECRET, secret.value
    assert_not_includes raw_value(secret).to_s, SECRET, "the value is stored encrypted"
    assert_equal "app_assistant", body.dig("project", "target_agent", "kind")
    assert_equal project.target_agent, project.evaluation.agent, "the project's evaluation belongs to its agent"
    assert_equal [ :project ], usage
  end

  test "picking a repository the connection has not selected selects it, which needs :manage_github" do
    stub_request(:get, "https://api.github.com/repos/acme/billing")
      .to_return(status: 200, body: { id: 9, full_name: "acme/billing", private: true, default_branch: "main" }.to_json)
    stub_contents("acme/billing", "Gemfile.lock" => rails_lock, "config/application.rb" => "# app\n")
    ActionAgent.permission_checker = ->(_user, action, _subject) { action != :manage_github }

    post BASE, params: { repository: "acme/billing" }, as: :json

    assert_response :forbidden
    assert_equal "manage_github", JSON.parse(response.body)["permission"]
    assert_equal 0, ActionAgent::Project.count
    assert_equal [ "acme/shop" ], @connection.reload.repository_names
    assert_not_requested(:get, %r{\Ahttps://api\.github\.com/repos/acme/billing})

    ActionAgent.permission_checker = nil
    post BASE, params: { repository: "acme/billing" }, as: :json

    assert_response :created, response.body
    assert_equal %w[acme/shop acme/billing], @connection.reload.repository_names
  end

  test "a quota denial creates nothing" do
    stub_supported_repository
    asked = []
    ActionAgent.quota_checker = ->(_owner, kind) { asked << kind; kind == :project ? { message: "Projects are a paid feature" } : nil }

    post BASE, params: { repository: "acme/shop", secrets: [ { name: "STRIPE_SECRET_KEY", value: SECRET } ] }, as: :json

    assert_response :payment_required
    assert_equal "Projects are a paid feature", JSON.parse(response.body)["message"]
    assert_equal [ :project ], asked
    assert_equal [ 0, 0, 0 ], [ ActionAgent::Project.count, ActionAgent::ProjectSecret.count, ActionAgent::Agent.count ]
  end

  test "an unsupported repository is refused at pick time with the reason" do
    stub_contents("acme/shop", "Gemfile.lock" => rails_lock(railties: "7.1.3"), "config/application.rb" => "# app\n")

    post BASE, params: { repository: "acme/shop" }, as: :json

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "unsupported_repository", body["code"]
    assert_equal "acme/shop locks railties 7.1.3; the engine needs Rails 7.2 or later", body["error"]
    assert_equal 0, ActionAgent::Project.count
  end

  test "refused secret names answer 422 and set nothing" do
    stub_supported_repository
    post BASE, params: { repository: "acme/shop", secrets: [ { name: "RUBYOPT", value: "-rinjected" } ] }, as: :json
    assert_response :unprocessable_entity
    assert_match(/RUBYOPT is set by the sandbox or changes how code is loaded/, response.body)
    assert_equal 0, ActionAgent::Project.count

    project = create_project!
    %w[PATH RUBYLIB LD_PRELOAD DYLD_INSERT_LIBRARIES BUNDLE_GEMFILE GIT_DIR NODE_OPTIONS PORT DATABASE_URL QUEUE_DATABASE_URL
       ACTION_AGENT_SANDBOX_TOKEN].each do |name|
      put "#{BASE}/#{project.id}/secrets", params: { secrets: [ { name: "FINE_ONE", value: SECRET }, { name: name, value: "x" * 12 } ] },
        as: :json
      assert_response :unprocessable_entity, "#{name} must be refused"
    end
    assert_equal 0, project.secrets.count, "a refused name leaves the whole list unset"
  end

  # --- secrets --------------------------------------------------------------

  test "the Environment tab lists names, sources and setters, never values, with warnings on save" do
    project = create_project!

    put "#{BASE}/#{project.id}/secrets",
      params: { secrets: [ { name: "STRIPE_SECRET_KEY", value: "sk_live_#{SECRET}" }, { name: "PIN", value: "1234" },
                           { name: "RAILS_MASTER_KEY", value: SECRET.reverse } ] }, as: :json

    assert_response :success, response.body
    assert_no_secret_in(response.body)
    saved = JSON.parse(response.body)["saved"].index_by { |secret| secret["name"] }
    assert_equal [ "live_credential" ], saved["STRIPE_SECRET_KEY"]["warnings"].map { |warning| warning["code"] }
    assert_equal [ "short_value" ], saved["PIN"]["warnings"].map { |warning| warning["code"] }
    assert_equal [ "rails_master_key" ], saved["RAILS_MASTER_KEY"]["warnings"].map { |warning| warning["code"] }

    get "#{BASE}/#{project.id}/secrets"
    listed = JSON.parse(response.body)["secrets"]
    assert_equal %w[PIN RAILS_MASTER_KEY STRIPE_SECRET_KEY], listed.map { |secret| secret["name"] }
    assert_equal %w[name provider set_by source updated_at], listed.first.keys.sort
    assert_no_secret_in(response.body)
    assert_not_includes response.body, "1234"

    put "#{BASE}/#{project.id}/secrets/PIN", params: { value: "a-longer-pin-value" }, as: :json
    assert_response :success
    assert_equal "a-longer-pin-value", project.secrets.find_by(name: "PIN").value
    assert_not_includes response.body, "a-longer-pin-value"

    delete "#{BASE}/#{project.id}/secrets/PIN"
    assert_response :no_content
    assert_not project.secrets.exists?(name: "PIN")
  end

  test "replacing and deleting a secret answer 403 when :manage_project_secrets is denied" do
    project = create_project!
    project.assign_secret(name: "STRIPE_SECRET_KEY", value: SECRET).save!
    asked = []
    ActionAgent.permission_checker = lambda do |_user, action, subject|
      asked << [ action, subject.class.name ]
      action != :manage_project_secrets
    end

    put "#{BASE}/#{project.id}/secrets/STRIPE_SECRET_KEY", params: { value: "replaced-value-0123" }, as: :json
    assert_response :forbidden
    put "#{BASE}/#{project.id}/secrets", params: { secrets: [ { name: "NEW_ONE", value: "new-value-0123" } ] }, as: :json
    assert_response :forbidden
    delete "#{BASE}/#{project.id}/secrets/STRIPE_SECRET_KEY"
    assert_response :forbidden

    assert_equal SECRET, project.secrets.find_by(name: "STRIPE_SECRET_KEY").value
    assert_not project.secrets.exists?(name: "NEW_ONE")
    assert_equal [ [ :manage_project_secrets, "ActionAgent::ProjectSecret" ] ], asked.uniq
    get "#{BASE}/#{project.id}/secrets"
    assert_response :success, "reading names needs no permission"
  end

  test "the organization's key needs consent, is never copied, and needs an organization key" do
    project = create_project!

    put "#{BASE}/#{project.id}/secrets", params: { secrets: [ { name: "OPENAI_API_KEY", source: "organization_key" } ] }, as: :json
    assert_response :unprocessable_entity
    assert_match(/needs consent/, response.body)

    put "#{BASE}/#{project.id}/secrets",
      params: { secrets: [ { name: "OPENAI_API_KEY", source: "organization_key", consent: true } ] }, as: :json
    assert_response :unprocessable_entity
    assert_match(/The organization has no openai key/, response.body)

    put "#{BASE}/#{project.id}/secrets",
      params: { secrets: [ { name: "STRIPE_SECRET_KEY", source: "organization_key", consent: true } ] }, as: :json
    assert_response :unprocessable_entity
    assert_match(/offered only for/, response.body)

    key = ActionAgent::ProviderKey.create!(provider: "openai", credential: "sk-org-openai-0123456789")
    put "#{BASE}/#{project.id}/secrets",
      params: { secrets: [ { name: "OPENAI_API_KEY", source: "organization_key", consent: true } ] }, as: :json

    assert_response :success, response.body
    assert_not_includes response.body, key.credential
    secret = project.secrets.sole
    assert_equal [ "organization_key", "openai", nil ], [ secret.source, secret.provider, secret.value ]
    assert secret.consented_at
    assert_nil raw_value(secret), "no copy of the key is stored"
    assert_equal({ "OPENAI_API_KEY" => key.credential }, project.reload.boot_spec.secrets)

    key.destroy!
    error = assert_raises(ActiveRecord::RecordNotFound) { project.reload.boot_spec }
    assert_match(/no longer stored/, error.message)
  end

  test "using the organization's key also needs :manage_credentials, asked about the key it hands over" do
    key = ActionAgent::ProviderKey.create!(provider: "openai", credential: "sk-org-openai-0123456789")
    project = create_project!
    asked = []
    ActionAgent.permission_checker = lambda do |_user, action, subject|
      asked << [ action, subject.class.name ]
      action != :manage_credentials
    end
    organization_key = { name: "OPENAI_API_KEY", source: "organization_key", consent: true }

    put "#{BASE}/#{project.id}/secrets", params: { secrets: [ organization_key ] }, as: :json
    assert_response :forbidden
    assert_equal "manage_credentials", JSON.parse(response.body)["permission"]
    put "#{BASE}/#{project.id}/secrets/OPENAI_API_KEY", params: organization_key.except(:name), as: :json
    assert_response :forbidden
    stub_supported_repository
    post BASE, params: { repository: "acme/shop", name: "Second", secrets: [ organization_key ] }, as: :json
    assert_response :forbidden

    assert_equal 0, ActionAgent::ProjectSecret.count
    assert_equal 1, ActionAgent::Project.count
    assert_equal [ [ :manage_project_secrets, "ActionAgent::ProjectSecret" ], [ :manage_credentials, "ActionAgent::ProviderKey" ] ],
      asked.uniq

    put "#{BASE}/#{project.id}/secrets", params: { secrets: [ { name: "OPENAI_API_KEY", value: "sk-project-own-0123456789" } ] },
      as: :json
    assert_response :success, "a value of the project's own needs no :manage_credentials"

    ActionAgent.permission_checker = nil
    put "#{BASE}/#{project.id}/secrets", params: { secrets: [ organization_key ] }, as: :json
    assert_response :success
    assert_equal({ "OPENAI_API_KEY" => key.credential }, project.reload.boot_spec.secrets)
  end

  # --- ownership --------------------------------------------------------------

  test "projects and their secrets are out of reach of another account, also one whose id is the creator's user id" do
    use_accounts!
    me = create_user("Creator")
    teammate = create_user("Teammate")
    mine = ProjectTestAccount.create!(id: me.id + 1000, name: "Mine")
    # The bug this guards against reads the account id where the user id
    # belongs: an account whose id is the creator's user id.
    other = ProjectTestAccount.create!(id: me.id, name: "Other")
    stranger = create_user("Stranger")
    @connection.update_columns(account_id: mine.id)
    user = me
    account = mine
    ActionAgent.current_user_resolver = ->(_controller) { user }
    ActionAgent.current_account_resolver = ->(_controller) { account }
    stub_supported_repository

    post BASE, params: { repository: "acme/shop", secrets: [ { name: "STRIPE_SECRET_KEY", value: SECRET } ] }, as: :json
    assert_response :created, response.body
    project = ActionAgent::Project.sole
    assert_equal [ mine.id, me.id ], [ project.account_id, project.user_id ]
    assert_equal [ mine.id, me.id ], project.secrets.sole.slice(:account_id, :user_id).values
    assert_equal [ mine.id, me.id ], [ project.target_agent.account_id, project.target_agent.user_id ]

    user = stranger
    account = other
    get BASE
    assert_equal [], JSON.parse(response.body)["projects"]
    get "#{BASE}/#{project.id}"
    assert_response :not_found
    get "#{BASE}/#{project.id}/secrets"
    assert_response :not_found
    put "#{BASE}/#{project.id}/secrets", params: { secrets: [ { name: "STRIPE_SECRET_KEY", value: "theirs-0123456789" } ] }, as: :json
    assert_response :not_found
    delete "#{BASE}/#{project.id}/secrets/STRIPE_SECRET_KEY"
    assert_response :not_found
    post "#{BASE}/#{project.id}/boot", as: :json
    assert_response :not_found
    assert_equal SECRET, project.secrets.sole.value

    user = teammate
    account = mine
    get BASE
    assert_equal [ project.id ], JSON.parse(response.body)["projects"].map { |listed| listed["id"] }
  end

  # --- booting --------------------------------------------------------------

  test "a boot hands the backend the project's secrets in memory only, and settles the project when it serves" do
    project = create_project!(secrets: { "STRIPE_SECRET_KEY" => SECRET })

    post "#{BASE}/#{project.id}/boot", as: :json

    assert_response :accepted, response.body
    assert_no_secret_in(response.body)
    assert_no_secret_in(enqueued_jobs.map { |job| job["arguments"] }.to_json)
    sandbox = project.reload.current_sandbox_session
    assert_equal [ "booting", project.id ], [ project.status, sandbox.project_id ]
    assert_equal [ { "key" => sandbox.runtime_server_key, "name" => "acme/shop (sandbox)" } ], project.target_agent.mcp_servers

    perform_enqueued_jobs

    _verb, session_id, spec = ProjectBackend.calls.sole
    assert_equal sandbox.session_id, session_id
    assert_equal({ "STRIPE_SECRET_KEY" => SECRET }, spec["secrets"])
    assert_equal [ "bootstrap", "without_engine", true ], spec.values_at("kind", "apply", "keep_on_failure")
    assert sandbox.reload.ready?
    assert_equal [ "ready", "bootstrapped", "ready" ], project.reload.values_at(:status, :install_state, :sandbox_state)

    post "#{BASE}/#{project.id}/boot", as: :json
    assert_response :ok
    assert_equal sandbox.session_id, JSON.parse(response.body).dig("sandbox", "session_id"), "a live sandbox is reused"
    assert_equal 1, ProjectBackend.calls.size
  end

  test "a failed boot's error is scrubbed of the project's secrets and their encodings" do
    project = create_project!(secrets: { "STRIPE_SECRET_KEY" => SECRET })
    ProjectBackend.create_error = RuntimeError.new(
      "boot failed: #{SECRET} #{CGI.escape(SECRET)} #{ERB::Util.url_encode(SECRET)} #{[ SECRET ].pack("m0")}"
    )

    perform_enqueued_jobs { post "#{BASE}/#{project.id}/boot", as: :json }

    sandbox = project.reload.current_sandbox_session
    assert sandbox.failed?
    assert_equal "failed", project.status
    assert_equal "boot failed: [REDACTED] [REDACTED] [REDACTED] [REDACTED]", sandbox.error_message
    get "#{BASE}/#{project.id}/boot"
    assert_no_secret_in(response.body)
  end

  test "a failed boot whose workspace was kept is resumed with the secrets again" do
    project = create_project!(secrets: { "STRIPE_SECRET_KEY" => SECRET })
    perform_enqueued_jobs { post "#{BASE}/#{project.id}/boot", as: :json }
    sandbox = project.reload.current_sandbox_session
    sandbox.update!(status: :failed, error_message: "db_prepare failed")
    project.update!(status: "failed")
    ProjectBackend.boot_state = { mode: "spec", kind: "bootstrap", failed_step: "db_prepare", kept: true, steps: [] }

    perform_enqueued_jobs { post "#{BASE}/#{project.id}/boot", as: :json }

    assert_response :ok
    assert_equal sandbox, project.reload.current_sandbox_session, "the kept boot is resumed, not replaced"
    verb, session_id, from, spec = ProjectBackend.calls.last
    assert_equal [ :resume_boot, sandbox.session_id, nil ], [ verb, session_id, from ]
    assert_equal({ "STRIPE_SECRET_KEY" => SECRET }, spec["secrets"])
    assert sandbox.reload.ready?
    assert_equal "ready", project.reload.status
  end

  test "an expired sandbox is replaced by a new boot, and the agent follows it" do
    project = create_project!
    perform_enqueued_jobs { post "#{BASE}/#{project.id}/boot", as: :json }
    old = project.reload.current_sandbox_session
    old.update_columns(expires_at: 1.minute.ago)

    perform_enqueued_jobs { post "#{BASE}/#{project.id}/boot", as: :json }

    assert_response :accepted
    fresh = project.reload.current_sandbox_session
    assert_not_equal old, fresh
    assert fresh.ready?
    assert old.reload.expired?
    assert_equal [ fresh.runtime_server_key ], project.target_agent.mcp_servers.map { |entry| entry["key"] }
  end

  test "the agent follows each new sandbox and keeps the servers and edits made in the agent editor" do
    project = create_project!
    agent = project.target_agent
    agent.update!(instructions: "Edited by hand.", mcp_servers: [ { "key" => "github" }, "sandbox:gone", "docs" ])

    perform_enqueued_jobs { post "#{BASE}/#{project.id}/boot", as: :json }

    first = project.reload.current_sandbox_session
    assert_equal [ { "key" => first.runtime_server_key, "name" => "acme/shop (sandbox)" }, { "key" => "github" }, "docs" ],
      agent.reload.mcp_servers

    patch "#{BASE}/#{project.id}/target", params: { app_assistant: true }, as: :json
    assert_response :success
    assert_equal "Edited by hand.", agent.reload.instructions, "choosing the target it has keeps the edits"
    assert_equal [ first.runtime_server_key, "github", "docs" ],
      agent.mcp_servers.map { |entry| entry.is_a?(Hash) ? entry["key"] : entry }

    first.update_columns(expires_at: 1.minute.ago)
    perform_enqueued_jobs { post "#{BASE}/#{project.id}/boot", as: :json }
    second = project.reload.current_sandbox_session
    assert_equal [ second.runtime_server_key, "github", "docs" ],
      agent.reload.mcp_servers.map { |entry| entry.is_a?(Hash) ? entry["key"] : entry }
  end

  test "boot progress lists each step with its elapsed time and the scrubbed tail of the failing step's log" do
    project = create_project!(secrets: { "STRIPE_SECRET_KEY" => SECRET })
    perform_enqueued_jobs { post "#{BASE}/#{project.id}/boot", as: :json }
    project.reload.current_sandbox_session.update!(status: :failed, error_message: "db_prepare failed with #{SECRET}")
    ProjectBackend.boot_state = {
      mode: "spec", kind: "bootstrap", failed_step: "db_prepare", kept: false, resumable_steps: [],
      steps: [
        { name: "checkout", status: "succeeded", duration_ms: 1200 },
        { name: "db_prepare", status: "failed", duration_ms: 3400, detail: "`bin/rails db:prepare` exited with 1 (#{SECRET})" }
      ]
    }
    long_log = "#{"x" * 9000}\nconnecting with #{SECRET}\nPG::ConnectionBad\n"
    ProjectBackend.log_pages = { "db_prepare" => long_log }

    get "#{BASE}/#{project.id}/boot"

    assert_response :success
    assert_no_secret_in(response.body)
    body = JSON.parse(response.body)
    assert_equal [ [ "checkout", "succeeded", 1200 ], [ "db_prepare", "failed", 3400 ] ],
      body.dig("boot", "steps").map { |step| step.values_at("name", "status", "duration_ms") }
    assert_equal "db_prepare", body.dig("log_tail", "step")
    assert_equal "connecting with [REDACTED]\nPG::ConnectionBad\n", body.dig("log_tail", "text")
    assert_equal true, body.dig("log_tail", "truncated")
    assert_equal "db_prepare failed with [REDACTED]", body["error"]

    get "#{BASE}/#{project.id}/boot_log", params: { step: "db_prepare", offset: 9000 }
    assert_response :success
    assert_no_secret_in(response.body)
  end

  test "the sandboxes API scrubs a project's secrets from its sandbox's boot status and logs too" do
    project = create_project!(secrets: { "STRIPE_SECRET_KEY" => SECRET })
    perform_enqueued_jobs { post "#{BASE}/#{project.id}/boot", as: :json }
    sandbox = project.reload.current_sandbox_session
    ProjectBackend.boot_state = { mode: "spec", kind: "bootstrap", failed_step: nil, kept: false,
                                  steps: [ { name: "db_prepare", status: "succeeded", detail: "saw #{SECRET}" } ] }
    ProjectBackend.log_pages = { "db_prepare" => "connecting with #{[ SECRET ].pack("m0")}\n" }

    get "/activeagents/api/sandboxes/#{sandbox.session_id}/boot"
    assert_response :success
    assert_includes response.body, "saw [REDACTED]"
    assert_no_secret_in(response.body)

    get "/activeagents/api/sandboxes/#{sandbox.session_id}/boot_log", params: { step: "db_prepare" }
    assert_response :success
    assert_equal "connecting with [REDACTED]\n", JSON.parse(response.body)["text"]
  end

  test "the first boot on :local asks for confirmation naming the repository, and later boots do not" do
    ActionAgent.sandbox_service = "local_project"
    project = create_project!

    post "#{BASE}/#{project.id}/boot", as: :json

    assert_response :conflict
    body = JSON.parse(response.body)
    assert_equal "confirmation_required", body["code"]
    assert_equal "This runs acme/shop's code on this machine as #{ActionAgent::Project.machine_user}.", body["confirmation"]
    assert_nil project.reload.current_sandbox_session

    perform_enqueued_jobs { post "#{BASE}/#{project.id}/boot", params: { confirm: true }, as: :json }
    assert_response :accepted
    assert project.reload.settings["local_boot_confirmed_at"].present?

    project.current_sandbox_session.update_columns(expires_at: 1.minute.ago)
    perform_enqueued_jobs { post "#{BASE}/#{project.id}/boot", as: :json }
    assert_response :accepted, "a later boot is not asked about again"
  end

  test "a backend that takes no boot spec cannot boot a project" do
    project = create_project!
    ActionAgent.sandbox_service = "plain"

    post "#{BASE}/#{project.id}/boot", as: :json

    assert_response :unprocessable_entity
    assert_match(/takes no boot spec/, JSON.parse(response.body)["error"])
    assert_nil project.reload.current_sandbox_session
  end

  # --- evaluating -------------------------------------------------------------

  test "running the evaluation boots an expired sandbox, waits for it, and completes the run against it" do
    ActionAgent.provider_credentials_resolver = lambda do |_owner, provider|
      provider == "openai" ? { access_token: "synthetic-fixture-key", api_version: :chat } : {}
    end
    project = create_project!(secrets: { "STRIPE_SECRET_KEY" => SECRET })
    project.target_agent.update!(provider: "openai", model: "gpt-4o-mini")
    project.evaluation.scenarios.create!(key: "find_order", prompt: "Where is order A-17?", expectations: { "tools" => [ "lookup_order" ] })
    perform_enqueued_jobs { post "#{BASE}/#{project.id}/boot", as: :json }
    expired = project.reload.current_sandbox_session
    expired.update_columns(expires_at: 1.minute.ago)
    stub_runtime
    stub_model

    post "#{BASE}/#{project.id}/run_evaluation", as: :json

    assert_response :accepted, response.body
    run = ActionAgent::EvaluationRun.find(JSON.parse(response.body).dig("run", "id"))
    assert run.pending?
    fresh = project.reload.current_sandbox_session
    assert_not_equal expired, fresh
    assert_no_secret_in(enqueued_jobs.map { |job| job["arguments"] }.to_json)

    perform_enqueued_jobs

    assert run.reload.complete?, run.error_message
    assert_equal fresh.session_id, run.sandbox["session_id"]
    assert run.scenario_results.sole.passed?
    assert_requested(:post, RUNTIME_URL, headers: { "Authorization" => "Bearer #{RUNTIME_TOKEN}" }, at_least_times: 1) do |request|
      JSON.parse(request.body)["method"] == "tools/call"
    end
  end

  test "a run fails with the reason when the project's boot fails" do
    project = create_project!
    ProjectBackend.create_error = RuntimeError.new("preflight refused acme/shop")

    post "#{BASE}/#{project.id}/run_evaluation", as: :json
    assert_response :accepted
    run = ActionAgent::EvaluationRun.find(JSON.parse(response.body).dig("run", "id"))
    perform_enqueued_jobs

    assert run.reload.failed?
    assert_equal "The project's sandbox failed to boot: preflight refused acme/shop", run.error_message
  end

  test "a run waits while the sandbox boots, and the evaluation needs a target first" do
    project = create_project!(engine: true)
    post "#{BASE}/#{project.id}/run_evaluation", as: :json
    assert_response :conflict
    assert_equal "no_target", JSON.parse(response.body)["code"]

    project = create_project!(name: "Second")
    post "#{BASE}/#{project.id}/run_evaluation", as: :json
    run = ActionAgent::EvaluationRun.find(JSON.parse(response.body).dig("run", "id"))
    clear_enqueued_jobs
    ActionAgent::ProjectEvaluationJob.perform_now(project.id, run.id)

    assert run.reload.pending?, "still booting: checked again later"
    assert_enqueued_with(job: ActionAgent::ProjectEvaluationJob, args: [ project.id, run.id ])
  end

  test "an installed repository targets the synced agent picked from its running sandbox" do
    project = create_project!(engine: true)
    assert_nil project.target_agent, "nothing to evaluate until a synced agent is picked"
    get "#{BASE}/#{project.id}/synced_agents"
    assert_response :conflict

    perform_enqueued_jobs { post "#{BASE}/#{project.id}/boot", as: :json }
    assert_equal "installed", project.reload.install_state, "an installed repository stays installed"
    stub_runtime(tools: [ { name: "run_support", description: "Ask the support agent" }, { name: "run_billing" },
                          { name: "run_support__triage" }, { name: "lookup_order" } ])

    get "#{BASE}/#{project.id}/synced_agents"
    assert_response :success, response.body
    assert_equal %w[support billing], JSON.parse(response.body)["synced_agents"].map { |agent| agent["slug"] }

    patch "#{BASE}/#{project.id}/target", params: { synced_agent: "nope" }, as: :json
    assert_response :unprocessable_entity

    patch "#{BASE}/#{project.id}/target", params: { synced_agent: "support" }, as: :json
    assert_response :success, response.body
    project.reload
    assert_equal [ "synced_agent", "support" ], JSON.parse(response.body)["project"]["target_agent"].values_at("kind", "synced_agent")
    assert_equal [ { "key" => project.current_sandbox_session.runtime_server_key, "name" => "acme/shop (sandbox)", "tools" => [ "run_support" ] } ],
      project.target_agent.mcp_servers
    assert_equal project.target_agent, project.evaluation.agent
    assert_includes project.target_agent.instructions, "`run_support`"
  end

  test "deleting a project removes its secrets, agent and evaluation and stops its sandbox" do
    project = create_project!(secrets: { "STRIPE_SECRET_KEY" => SECRET })
    perform_enqueued_jobs { post "#{BASE}/#{project.id}/boot", as: :json }
    sandbox = project.reload.current_sandbox_session

    delete "#{BASE}/#{project.id}"

    assert_response :no_content
    assert_equal [ 0, 0, 0, 0 ], [ ActionAgent::Project.count, ActionAgent::ProjectSecret.count, ActionAgent::Agent.count,
                                   ActionAgent::Evaluation.count ]
    assert sandbox.reload.expired?
  end

  test "deleting a project that has secrets needs :manage_project_secrets" do
    project = create_project!(secrets: { "STRIPE_SECRET_KEY" => SECRET })
    no_secrets = create_project!(name: "Second")
    asked = []
    ActionAgent.permission_checker = lambda do |_user, action, subject|
      asked << [ action, subject.class.name ]
      false
    end

    delete "#{BASE}/#{project.id}"

    assert_response :forbidden
    assert_equal "manage_project_secrets", JSON.parse(response.body)["permission"]
    assert_equal SECRET, project.secrets.sole.value
    assert_equal [ [ :manage_project_secrets, "ActionAgent::ProjectSecret" ] ], asked.uniq

    delete "#{BASE}/#{no_secrets.id}"
    assert_response :no_content
    assert_equal [ project ], ActionAgent::Project.all.to_a
  end

  test "a new ref needs what setting the secrets needs, is preflighted, and replaces the old ref's sandbox" do
    ActionAgent::ProviderKey.create!(provider: "openai", credential: "sk-org-openai-0123456789")
    project = create_project!(secrets: { "STRIPE_SECRET_KEY" => SECRET })
    perform_enqueued_jobs { post "#{BASE}/#{project.id}/boot", as: :json }
    old = project.reload.current_sandbox_session
    stub_contents("acme/shop", ref: "their-branch", "Gemfile.lock" => rails_lock, "config/application.rb" => "# app\n")
    ActionAgent.permission_checker = ->(_user, action, _subject) { action != :manage_project_secrets }

    patch "#{BASE}/#{project.id}", params: { default_ref: "their-branch" }, as: :json

    assert_response :forbidden
    assert_equal "manage_project_secrets", JSON.parse(response.body)["permission"]
    assert_nil project.reload.default_ref
    assert old.reload.ready?
    assert_not_requested(:get, "https://api.github.com/repos/acme/shop/commits", query: hash_including("sha" => "their-branch"))

    patch "#{BASE}/#{project.id}", params: { name: "Renamed" }, as: :json
    assert_response :success, "the name and start URL hand nothing over"
    assert_equal "Renamed", project.reload.name

    project.assign_secret(name: "OPENAI_API_KEY", source: "organization_key", consent: true).save!
    ActionAgent.permission_checker = ->(_user, action, _subject) { action != :manage_credentials }
    patch "#{BASE}/#{project.id}", params: { default_ref: "their-branch" }, as: :json
    assert_response :forbidden
    assert_equal "manage_credentials", JSON.parse(response.body)["permission"]

    ActionAgent.permission_checker = nil
    stub_contents("acme/shop", ref: "old-rails", "Gemfile.lock" => rails_lock(railties: "7.1.3"), "config/application.rb" => "# app\n")
    patch "#{BASE}/#{project.id}", params: { default_ref: "old-rails" }, as: :json
    assert_response :unprocessable_entity
    assert_equal "unsupported_repository", JSON.parse(response.body)["code"]
    assert_nil project.reload.default_ref

    stub_contents("acme/shop", ref: "their-branch", "config/application.rb" => "# app\n",
      "Gemfile.lock" => rails_lock(gems: [ "actionagent (1.9.0)", "activeagent (1.9.0)" ]))
    patch "#{BASE}/#{project.id}", params: { default_ref: "their-branch" }, as: :json

    assert_response :success, response.body
    project.reload
    assert_equal [ "their-branch", "installed", "draft", "their-branch" ],
      [ project.default_ref, project.install_state, project.status, project.settings.dig("preflight", "ref") ]
    assert old.reload.expired?, "the old ref's sandbox is stopped"
    assert_equal "expired", project.sandbox_state

    perform_enqueued_jobs { post "#{BASE}/#{project.id}/boot", as: :json }
    assert_response :accepted
    assert_equal "their-branch", project.reload.current_sandbox_session.repository_ref
  end

  test "moving an installed project to a ref without the engine gives it the App assistant" do
    project = create_project!(engine: true)
    assert_nil project.target_agent
    stub_contents("acme/shop", ref: "plain", "Gemfile.lock" => rails_lock, "config/application.rb" => "# app\n")

    patch "#{BASE}/#{project.id}", params: { default_ref: "plain" }, as: :json

    assert_response :success, response.body
    body = JSON.parse(response.body)["project"]
    assert_equal [ "plain", "detected", "app_assistant" ], [ body["default_ref"], body["install_state"], body.dig("target_agent", "kind") ]

    patch "#{BASE}/#{project.id}", params: { default_ref: "plain" }, as: :json
    assert_response :success
    assert_requested(:get, "https://api.github.com/repos/acme/shop/commits", query: hash_including("sha" => "plain"), times: 1)
  end

  test "broadcasts name the project and its status, never a secret" do
    sent = []
    project = create_project!(secrets: { "STRIPE_SECRET_KEY" => SECRET })

    ActionAgent::LiveUpdates.stub(:broadcast, ->(stream, **payload) { sent << [ stream, payload ] && true }) do
      perform_enqueued_jobs { post "#{BASE}/#{project.id}/boot", as: :json }
    end

    assert_includes sent, [ "project_#{project.id}", { type: "project", id: project.id, status: "booting" } ]
    assert_includes sent, [ "project_#{project.id}", { type: "project", id: project.id, status: "ready" } ]
    assert_no_secret_in(sent.to_json)
  end

  private

  def repo_row(full_name, default_branch: "main")
    { "id" => full_name.hash.abs % 100_000, "full_name" => full_name, "private" => true, "default_branch" => default_branch }
  end

  def json_headers = { "Content-Type" => "application/json" }

  # The commit the stubs say +ref+ names in +repository+.
  def commit_for(repository, ref) = Digest::SHA1.hexdigest("#{repository}@#{ref}")

  # Has +ref+ name +commit+ in +repository+, and serves +files+ from
  # GitHub's contents API at that commit, alongside what earlier calls serve
  # at other commits. Any other path answers 404.
  def stub_contents(repository, ref: "main", commit: commit_for(repository, ref), **files)
    stub_commit(repository, ref, commit)
    served[[ repository, commit ]] = files
    stub_request(:get, %r{\Ahttps://api\.github\.com/repos/#{Regexp.escape(repository)}/contents/}).to_return do |request|
      uri = URI(request.uri.to_s)
      path = uri.path.delete_prefix("/repos/#{repository}/contents/").split("/").map { |part| CGI.unescape(part) }.join("/")
      content = served[[ repository, Rack::Utils.parse_query(uri.query)["ref"] ]]&.dig(path)
      if content
        { status: 200, headers: json_headers,
          body: { type: "file", encoding: "base64", size: content.bytesize, content: [ content ].pack("m") }.to_json }
      else
        { status: 404, headers: json_headers, body: { message: "Not Found" }.to_json }
      end
    end
  end

  def stub_commit(repository, ref, commit = commit_for(repository, ref))
    stub_request(:get, "https://api.github.com/repos/#{repository}/commits").with(query: { "sha" => ref, "per_page" => "1" })
      .to_return(status: 200, headers: json_headers, body: [ { sha: commit } ].to_json)
  end

  def served
    @served ||= {}
  end

  def stub_tree(repository, ref, paths, commit: commit_for(repository, ref))
    stub_commit(repository, ref, commit)
    stub_request(:get, "https://api.github.com/repos/#{repository}/git/trees/#{commit}?recursive=1")
      .to_return(status: 200, headers: json_headers,
        body: { tree: paths.map { |path| { path: path, type: "blob", size: 100 } } + [ { path: "config", type: "tree" } ],
                truncated: false }.to_json)
  end

  def stub_supported_repository(engine: false)
    gems = engine ? [ "actionagent (1.9.0)", "activeagent (1.9.0)" ] : []
    stub_contents("acme/shop", "Gemfile.lock" => rails_lock(gems: gems), "config/application.rb" => "# app\n")
  end

  def rails_lock(ruby: "3.3.6p0", railties: "8.0.1", gems: [])
    specs = [ "rails (#{railties})", "railties (#{railties})", *gems ].sort.map { |spec| "    #{spec}\n" }.join
    lock = +"GEM\n  remote: https://rubygems.org/\n  specs:\n#{specs}\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n  rails\n"
    lock << "\nRUBY VERSION\n   ruby #{ruby}\n" if ruby
    lock << "\nBUNDLED WITH\n   2.6.2\n"
  end

  def discover(repository)
    get "#{BASE}/discover_secrets", params: { repository: repository }
    assert_response :success, response.body
    JSON.parse(response.body)
  end

  # A project made through the API, so it is owned and set up the way a
  # request makes one.
  def create_project!(name: "Shop", engine: false, secrets: {})
    stub_supported_repository(engine: engine)
    post BASE, params: { repository: "acme/shop", name: name,
                         secrets: secrets.map { |key, value| { name: key, value: value } } }, as: :json
    assert_response :created, response.body
    ActionAgent::Project.find(JSON.parse(response.body).dig("project", "id"))
  end

  def raw_value(secret)
    ActionAgent::ProjectSecret.connection.select_value(
      "SELECT value FROM #{ActionAgent::ProjectSecret.quoted_table_name} WHERE id = #{secret.id.to_i}"
    )
  end

  def assert_no_secret_in(text)
    ActionAgent::SecretScrubber.with_encodings([ SECRET ]).each do |form|
      assert_not_includes text, form, "#{form.inspect} leaked"
    end
  end

  def use_accounts!
    ActionAgent.multi_tenant = true
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "ProjectTestAccount"
  end

  def create_user(name)
    User.create!(name: name, email: "#{name.parameterize}-#{SecureRandom.hex(3)}@example.com", age: 30)
  end

  # The sandbox's MCP endpoint, answering only a request with its token.
  def stub_runtime(tools: nil)
    tools ||= [ { name: "lookup_order", description: "Find an order by id.",
                  inputSchema: { type: "object", properties: { id: { type: "string" } }, required: [ "id" ] } } ]
    stub_request(:post, RUNTIME_URL)
      .with(headers: { "Authorization" => "Bearer #{RUNTIME_TOKEN}" })
      .to_return do |request|
        payload = JSON.parse(request.body)
        result =
          case payload["method"]
          when "initialize" then { protocolVersion: "2025-03-26", capabilities: { tools: {} } }
          when "tools/list" then { tools: tools }
          when "tools/call" then { content: [ { type: "text", text: "order #{payload.dig("params", "arguments", "id")} shipped" } ] }
          end

        if payload.key?("id")
          { status: 200, body: { jsonrpc: "2.0", id: payload["id"], result: result }.to_json,
            headers: { "Content-Type" => "application/json", "Mcp-Session-Id" => "runtime-session" } }
        else
          { status: 202, body: "" }
        end
      end
  end

  # The model: asks for lookup_order, then answers from its result.
  def stub_model
    stub_request(:post, CHAT_URL).to_return do |request|
      messages = JSON.parse(request.body)["messages"]
      message =
        if messages.any? { |entry| entry["role"] == "tool" }
          { role: "assistant", content: "Order A-17 has shipped." }
        else
          { role: "assistant", content: nil, tool_calls: [
            { id: "call_1", type: "function", function: { name: "lookup_order", arguments: { id: "A-17" }.to_json } }
          ] }
        end

      { status: 200, headers: { "Content-Type" => "application/json" }, body: {
        id: "chat_fixture", object: "chat.completion", created: 1, model: "gpt-4o-mini",
        choices: [ { index: 0, message: message, finish_reason: message[:tool_calls] ? "tool_calls" : "stop" } ],
        usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 }
      }.to_json }
    end
  end
end
