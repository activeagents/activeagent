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
    step = steps.find { |entry| entry["name"] == "schema_tools" }
    assert step["always"], "a checkout that boots from its own sandbox.yml writes them too"
    remove, reservation, note = Shellwords.split(step["command"]).join(" ").split(" && ")
    assert remove.start_with?("[ ! -d app/agent_tools ] || find app/agent_tools "), remove
    assert_includes remove, "-exec grep -qF Managed by the ActiveAgent dashboard {} ; -exec rm -f {} ;",
      "first the files an earlier boot wrote go, so a model taken off the list loses its tools"
    assert reservation.start_with?("if [ -e app/agent_tools/reservation_tools.rb ]; then echo "), reservation
    assert reservation.end_with?("; else bin/rails generate active_agent:schema_tools Reservation --force --managed --filterable status " \
      "--returns status starts_at; fi"), "the choices survive the sandbox's expiry"
    assert_match(/generate active_agent:schema_tools Admin::Note --force --managed --returns body; fi\z/, note)
  end

  test "an installed project's boots, which run the checkout's own sandbox.yml, still write the choices" do
    boot!
    put "#{BASE}/#{@project.id}/schema_tools", params: { schema_tools: [ { model: "Reservation", returns: [ "status" ] } ] }, as: :json
    assert_response :success, response.body

    @project.reload.update!(install_state: "installed")
    spec = @project.boot_spec

    assert spec.without_engine_only?, "a checkout that bundles the engine boots as its sandbox.yml says"
    assert_equal [ "schema_tools" ], spec.always_steps.map { |step| step["name"] }
  end

  test "taking every model off the list leaves a step that removes the files the dashboard wrote" do
    boot!
    put "#{BASE}/#{@project.id}/schema_tools", params: { schema_tools: [ { model: "Reservation", returns: [ "status" ] } ] }, as: :json
    put "#{BASE}/#{@project.id}/schema_tools", params: { schema_tools: [] }, as: :json
    assert_response :success, response.body

    steps = @project.reload.boot_spec.always_steps
    assert_equal [ "schema_tools" ], steps.map { |step| step["name"] }
    assert_no_match(/generate/, steps.sole["command"])
    assert_match(/-exec rm -f/, steps.sole["command"])
    assert_empty ActionAgent::Project.new.then { |project| ActionAgent::SandboxBootSpec.schema_tools_steps(nil) },
      "a project that never chose writes and removes nothing"
  end

  test "many models are spread over several steps, and choices no boot could hold are refused" do
    columns = (1..20).map { |index| { "name" => "a_fairly_long_column_name_#{index}", "type" => "string" } }
    models = (1..12).map { |index| { "name" => "Model#{index}", "table" => "model#{index}s", "columns" => columns } }
    @project.update!(settings: @project.settings.merge("app_models" => models))
    choices = models.map { |model| { model: model["name"], filterable: columns.map { |c| c["name"] }, returns: columns.map { |c| c["name"] } } }

    put "#{BASE}/#{@project.id}/schema_tools", params: { schema_tools: choices }, as: :json

    assert_response :success, response.body
    steps = @project.reload.boot_spec.steps.select { |step| ActionAgent::SandboxBootSpec.schema_tools_step?(step["name"]) }
    assert_operator steps.size, :>, 1
    assert steps.all? { |step| step["command"].length <= ActionAgent::SandboxBootSpec::MAX_COMMAND_LENGTH }
    assert_equal models.map { |model| model["name"] },
      steps.flat_map { |step| step["command"].scan(/active_agent:schema_tools (\S+)/).flatten }
    assert_equal steps.map { |step| step["name"] }, [ "schema_tools", *(2..steps.size).map { |index| "schema_tools_#{index}" } ]

    wide = (1..100).map { |index| { "name" => "#{"c" * 50}_#{index}", "type" => "string" } }
    @project.update!(settings: @project.settings.merge("app_models" => [ { "name" => "Wide", "table" => "wides", "columns" => wide } ]))
    put "#{BASE}/#{@project.id}/schema_tools", params: { schema_tools: [ { model: "Wide", returns: wide.map { |c| c["name"] } } ] },
      as: :json

    assert_response :unprocessable_entity
    assert_match(/Wide has more columns chosen than one boot step can hold/, JSON.parse(response.body)["error"])
    assert_equal 12, @project.reload.schema_tools.size, "a refused choice changes nothing"
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
      ActionAgent::SandboxBootSpec.schema_tools_steps([ { "model" => "User", "returns" => [ "password_digest" ] } ])
    end
    assert_match(/User.password_digest looks like it holds a secret/, error.message)
    assert_raises(ActionAgent::SandboxBootSpec::Invalid) do
      ActionAgent::SandboxBootSpec.schema_tools_steps([ { "model" => "user; rm -rf /", "returns" => [] } ])
    end
  end

  test "the marker the steps look for is the one the framework's generator writes" do
    assert_equal ActiveAgent::SchemaTools::MANAGED_MARKER, ActionAgent::SandboxBootSpec::SCHEMA_TOOLS_MARKER
  end

  private

  def boot!
    perform_enqueued_jobs { @project.reload.ensure_sandbox! }
    assert @project.reload.ready?, @project.current_sandbox_session&.error_message
  end
end
