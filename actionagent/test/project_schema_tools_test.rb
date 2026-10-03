# frozen_string_literal: true

require "test_helper"

# "Choose what the assistant may read": the models a boot lists, the models
# and columns the developer chooses for the App assistant, and the boot step
# that writes their schema tools on every boot after that.
class ProjectSchemaToolsTest < ActionDispatch::IntegrationTest
  BASE = "/activeagents/api/projects"
  MODELS = [
    { "name" => "Reservation", "table" => "reservations",
      "columns" => [ { "name" => "status", "type" => "string" }, { "name" => "starts_at", "type" => "datetime" },
                     { "name" => "guest_name", "type" => "string" } ] },
    { "name" => "Admin::Note", "table" => "admin_notes", "columns" => [ { "name" => "body", "type" => "text" } ] }
  ].freeze

  # Boots every sandbox at once, listing MODELS in its manifest.
  class ListingBackend
    class << self
      attr_accessor :calls
    end
    self.calls = []

    def create_sandbox(session, boot_config: nil)
      self.class.calls << [ :create, session.session_id, boot_config ]
      { container_name: "listing-#{session.session_id}", url: "http://127.0.0.1:4400", mcp_url: "http://127.0.0.1:4400/activeagents/mcp",
        mcp_token: "aa_listing_token", app_models: MODELS }
    end

    def handle_for(session) = "listing-#{session.session_id}"
    def terminate(_handle) = true
    def status(_handle) = { status: "running" }
    def list_sandboxes = []
    def cleanup_expired = 0
  end

  def setup
    [ ActionAgent::Project, ActionAgent::ProjectSecret, ActionAgent::Evaluation, ActionAgent::Agent, ActionAgent::SandboxSession,
      ActionAgent::GithubConnection ].each(&:delete_all)
    ListingBackend.calls = []
    @original_backends = ActionAgent.sandbox_backends
    @original_service = ActionAgent.sandbox_service
    ActionAgent.sandbox_backends = { "listing" => ListingBackend.name }
    ActionAgent.sandbox_service = "listing"
    ActionAgent::GithubConnection.create!(access_token: "gho_schemaToolsToken0123456789", github_user_id: 7, login: "octocat",
      repositories: [ { "id" => 1, "full_name" => "acme/shop", "private" => true, "default_branch" => "main" } ])
    @project = ActionAgent::Project.create!(name: "Shop", repository: "acme/shop", install_state: "detected")
    @project.ensure_app_assistant!
  end

  def teardown
    ActionAgent.sandbox_backends = @original_backends
    ActionAgent.sandbox_service = @original_service
  end

  test "a boot's manifest lists the app's models on the project" do
    get "#{BASE}/#{@project.id}/app_models"
    assert_response :conflict

    boot!

    get "#{BASE}/#{@project.id}/app_models"
    assert_response :success
    assert_equal MODELS, JSON.parse(response.body)["models"]
    get "#{BASE}/#{@project.id}"
    assert JSON.parse(response.body).dig("project", "app_models_listed")
  end

  test "the chosen columns become a schema tools step after db_prepare, on every later boot" do
    boot!

    put "#{BASE}/#{@project.id}/schema_tools", params: { schema_tools: [
      { model: "Reservation", filterable: [ "status" ], returns: %w[status starts_at] },
      { model: "Admin::Note", returns: [ "body" ] }
    ] }, as: :json

    assert_response :success, response.body
    assert_equal false, JSON.parse(response.body)["rebooted"]
    assert_equal [ { "model" => "Reservation", "filterable" => [ "status" ], "returns" => %w[status starts_at] },
                   { "model" => "Admin::Note", "filterable" => [], "returns" => [ "body" ] } ], @project.reload.schema_tools

    @project.current_sandbox_session.update_columns(expires_at: 1.minute.ago)
    boot!
    steps = ListingBackend.calls.last[2]["steps"]
    names = steps.map { |step| step["name"] }
    assert_equal names.index("db_prepare") + 1, names.index("schema_tools")
    assert_equal "bin/rails generate active_agent:schema_tools Reservation --force --filterable status --returns status starts_at && " \
      "bin/rails generate active_agent:schema_tools Admin::Note --force --returns body",
      steps.find { |step| step["name"] == "schema_tools" }["command"], "the choices survive the sandbox's expiry"
  end

  test "applying the choices boots the project again, and the App assistant follows the new sandbox with every facade tool" do
    boot!
    first = @project.reload.current_sandbox_session

    perform_enqueued_jobs do
      put "#{BASE}/#{@project.id}/schema_tools", params: { schema_tools: [ { model: "Reservation", returns: [ "status" ] } ], apply: true },
        as: :json
    end

    assert_response :success, response.body
    assert JSON.parse(response.body)["rebooted"]
    assert first.reload.expired?
    current = @project.reload.current_sandbox_session
    assert_not_equal first.id, current.id
    assert current.ready?
    entry = @project.target_agent.reload.mcp_servers.find { |server| server["key"] == current.runtime_server_key }
    assert entry, @project.target_agent.mcp_servers.inspect
    assert_not entry.key?("tools"), "no allowlist: the assistant lists whatever the facade serves, the new schema tools among them"
  end

  test "only models and columns the boot listed can be chosen" do
    boot!

    {
      { model: "Invoice", returns: [ "total" ] } => /"Invoice" is not one of the app's models/,
      { model: "Reservation", returns: [ "card_number" ] } => /Reservation has no column card_number/,
      { model: "Reservation", filterable: [ "guest_name; rm -rf /" ] } => /has no column/
    }.each do |choice, message|
      put "#{BASE}/#{@project.id}/schema_tools", params: { schema_tools: [ choice ] }, as: :json

      assert_response :unprocessable_entity
      assert_match message, JSON.parse(response.body)["error"]
    end
    assert_empty @project.reload.schema_tools
  end

  test "choosing needs a boot that listed the models, and a project evaluated with the App assistant" do
    put "#{BASE}/#{@project.id}/schema_tools", params: { schema_tools: [ { model: "Reservation", returns: [ "status" ] } ] }, as: :json
    assert_response :unprocessable_entity
    assert_match(/Boot the project first/, JSON.parse(response.body)["error"])

    @project.update!(settings: @project.settings.merge("target_slug" => "support_bot"))
    put "#{BASE}/#{@project.id}/schema_tools", params: { schema_tools: [] }, as: :json
    assert_response :conflict
    assert_equal "not_app_assistant", JSON.parse(response.body)["code"]
  end

  test "a column that looks like a secret is never written into a step" do
    error = assert_raises(ActionAgent::SandboxBootSpec::Invalid) do
      ActionAgent::SandboxBootSpec.schema_tools_step([ { "model" => "User", "returns" => [ "password_digest" ] } ])
    end
    assert_match(/User.password_digest looks like it holds a secret/, error.message)
    assert_raises(ActionAgent::SandboxBootSpec::Invalid) do
      ActionAgent::SandboxBootSpec.schema_tools_step([ { "model" => "user; rm -rf /", "returns" => [] } ])
    end
    assert_nil ActionAgent::SandboxBootSpec.schema_tools_step([])
  end

  private

  def boot!
    perform_enqueued_jobs { @project.reload.ensure_sandbox! }
    assert @project.reload.ready?, @project.current_sandbox_session&.error_message
  end
end
