# frozen_string_literal: true

require "test_helper"
require_relative "support/explorer_setup"

# The test account step (Api::ProjectSignInsController): the credentials
# and the browser's saved sign-in are project secrets that never reach the
# sandbox's environment or a response, a check signs the browser in from the
# Rails process, and an app whose login page has no password field is
# reported as unsupported.
class ProjectSignInsApiTest < ActionDispatch::IntegrationTest
  include ExplorerSetup

  BASE = "/activeagents/api/projects"

  def setup
    setup_explorer_world!
  end

  def teardown
    restore_explorer_settings!
    ActionAgent.permission_checker = nil
  end

  def sign_in_path(suffix = nil)
    [ "#{BASE}/#{@project.id}/sign_in", suffix ].compact.join("/")
  end

  test "the credentials are kept as a sign-in secret that no boot, response or listing reveals" do
    put sign_in_path, params: { login_url: "/users/sign_in", login: "dev@example.com", password: SENTINEL }, as: :json

    assert_response :success, response.body
    credentials = response.parsed_body.dig("sign_in", "credentials")
    assert_equal({ "secret_ref" => "APP_SIGN_IN", "login_url" => "/users/sign_in", "login" => "dev@example.com",
                   "password_set" => true, "fields" => {} }, credentials.except("updated_at"))
    secret = @project.secrets.find_by!(name: ActionAgent::Project::SIGN_IN_SECRET)
    assert_equal "sign_in", secret.kind
    assert_not_includes @project.reload.secret_environment.keys, "APP_SIGN_IN"
    assert_includes @project.scrub_values, SENTINEL

    get sign_in_path
    get "#{BASE}/#{@project.id}/secrets"
    assert_equal [ "sign_in" ], response.parsed_body["secrets"].select { |entry| entry["name"] == "APP_SIGN_IN" }.map { |entry| entry["kind"] }
    [ response.body, ActionAgent::Project.find(@project.id).summary.to_json ].each { |text| assert_not_includes text, SENTINEL }
  end

  test "credentials without a password, or with a login URL off the app, are refused" do
    put sign_in_path, params: { login_url: "/users/sign_in", login: "dev@example.com" }, as: :json
    assert_response :unprocessable_entity
    assert_match(/password/, response.parsed_body["error"])

    put sign_in_path, params: { login_url: "https://elsewhere.example/login", login: "a", password: SENTINEL }, as: :json
    assert_response :unprocessable_entity
    assert_match(/login_url/, response.parsed_body["error"])
    assert_not @project.secrets.exists?(name: "APP_SIGN_IN")
  end

  test "setting them needs :manage_project_secrets, asked about the secret" do
    asked = []
    ActionAgent.permission_checker = ->(_user, action, subject) { asked << [ action, subject.class.name, subject.kind ] and false }

    put sign_in_path, params: { login_url: "/login", login: "dev@example.com", password: SENTINEL }, as: :json

    assert_response :forbidden
    assert_equal [ [ :manage_project_secrets, "ActionAgent::ProjectSecret", "sign_in" ] ], asked
    assert_not @project.secrets.exists?(name: "APP_SIGN_IN")
  end

  test "an env secret cannot take over a sign-in secret's name" do
    @project.assign_sign_in({ login_url: "/login", login: "dev@example.com", password: SENTINEL }).save!

    put "#{BASE}/#{@project.id}/secrets/APP_SIGN_IN", params: { value: "plain-value-123" }, as: :json

    assert_response :unprocessable_entity
    assert_equal "sign_in", @project.secrets.find_by!(name: "APP_SIGN_IN").reload.kind
  end

  test "a check signs the browser in, starting it when none runs" do
    @project.assign_sign_in({ login_url: "/users/sign_in", login: "dev@example.com", password: SENTINEL }).save!

    post sign_in_path("check"), as: :json

    assert_response :success, response.body
    assert_equal "signed_in", response.parsed_body.dig("result", "status")
    assert_equal :headless, ExplorerBackend.launches.sole[:mode]
    assert_not_includes response.body, SENTINEL
  end

  test "a check of an app whose login page has no password field says it is not supported in the sandbox" do
    start_fake_browser!
    @browser.login_has_password = false
    @project.assign_sign_in({ login_url: "/login", login: "dev@example.com", password: SENTINEL }).save!

    post sign_in_path("check"), as: :json

    assert_response :success, response.body
    result = response.parsed_body["result"]
    assert_equal "unsupported", result["status"]
    assert_match(/not supported in the sandbox/, result["message"])
  end

  test "the running browser's sign-in is saved, and later browsers start with it" do
    start_fake_browser!
    state = { "cookies" => [ { "name" => "_shop_session", "value" => "signed-in-cookie-value", "domain" => "127.0.0.1", "path" => "/" } ],
              "origins" => [] }
    stub_request(:get, "http://127.0.0.1:4400/storage-state")
      .with(headers: { "Authorization" => "Bearer #{BROWSER_TOKEN}" })
      .to_return(status: 200, body: { storage_state: state }.to_json, headers: { "Content-Type" => "application/json" })

    post sign_in_path("save_browser"), as: :json

    assert_response :success, response.body
    assert response.parsed_body.dig("sign_in", "storage_state", "saved")
    assert_not_includes response.body, "signed-in-cookie-value"
    assert_equal state, @project.reload.saved_storage_state
    assert_includes @project.scrub_values, "signed-in-cookie-value"
    assert_not_includes @project.secret_environment.keys, "APP_STORAGE_STATE"

    ActionAgent::SandboxBrowser.stop(@sandbox)
    ActionAgent::SandboxBrowser.ensure_running!(@sandbox, storage_state: @project.saved_storage_state)
    assert_equal state, ExplorerBackend.launches.last[:storage_state]
  end

  test "saving needs a running browser, and no sign-in removes both secrets" do
    post sign_in_path("save_browser"), as: :json
    assert_response :conflict

    @project.assign_sign_in({ login_url: "/login", login: "dev@example.com", password: SENTINEL }).save!
    @project.assign_storage_state({ "cookies" => [], "origins" => [] }).save!
    delete sign_in_path, as: :json

    assert_response :success
    assert_equal({ "credentials" => nil, "storage_state" => nil, "browser_running" => false }, response.parsed_body["sign_in"])
    assert_equal [ "STRIPE_SECRET_KEY" ], @project.secrets.pluck(:name)
  end
end
