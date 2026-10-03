# frozen_string_literal: true

require "test_helper"

# A project's secrets as data: which names are refused, what the form warns
# about, the boot spec they travel in, and the scrub lists they join.
class ProjectSecretTest < ActiveSupport::TestCase
  SECRET = "sk_test_unit s3cret/value+0123"

  def setup
    ActionAgent::Project.delete_all
    ActionAgent::ProjectSecret.delete_all
    ActionAgent::SandboxSession.delete_all
    ActionAgent::CodeSession.delete_all
    ActionAgent::ProviderKey.delete_all
    @project = ActionAgent::Project.create!(name: "Shop", repository: "acme/shop")
  end

  test "names the sandbox sets, or that change how code loads, are refused; others are not" do
    refused = %w[PATH RUBYOPT RUBYLIB LD_PRELOAD DYLD_LIBRARY_PATH BUNDLE_GEMFILE BUNDLE_PATH GIT_DIR GIT_SSH_COMMAND NODE_OPTIONS
                 PORT DATABASE_URL CACHE_DATABASE_URL ACTION_AGENT_SANDBOX_MANIFEST]
    allowed = %w[STRIPE_SECRET_KEY OPENAI_API_KEY RAILS_MASTER_KEY BUNDLER_VERSION GITHUB_TOKEN DATABASE_HOST]

    refused.each do |name|
      secret = @project.assign_secret(name: name, value: SECRET)
      assert_not secret.valid?, "#{name} is refused"
      assert_includes secret.errors[:name].join, "set by the sandbox or changes how code is loaded"
    end
    allowed.each { |name| assert @project.assign_secret(name: name, value: SECRET).valid?, "#{name} is allowed" }
    assert_not @project.assign_secret(name: "not a name", value: SECRET).valid?
  end

  test "the sign-in's names are not environment variables" do
    [ ActionAgent::Project::SIGN_IN_SECRET, ActionAgent::Project::STORAGE_STATE_SECRET ].each do |name|
      secret = @project.assign_secret(name: name, value: SECRET)
      assert_not secret.valid?, "#{name} is refused"
      assert_includes secret.errors[:name].join, "keeps the project's sign-in"
    end
    assert @project.assign_sign_in({ password: "pw-0123456789" }).valid?
  end

  test "the form warns about live keys, values too short to mask, and the master key" do
    warnings = ->(name, value) { ActionAgent::ProjectSecret.warnings_for(name, value).map { |warning| warning[:code] } }

    assert_equal [ "live_credential" ], warnings.call("STRIPE_SECRET_KEY", "sk_live_0123456789")
    assert_equal [ "live_credential" ], warnings.call("STRIPE_RESTRICTED_KEY", "rk_live_0123456789")
    assert_equal [], warnings.call("STRIPE_SECRET_KEY", "sk_test_0123456789")
    assert_equal [ "short_value" ], warnings.call("PIN", "1234567")
    assert_equal [], warnings.call("PIN", "12345678")
    assert_equal [ "rails_master_key" ], warnings.call("RAILS_MASTER_KEY", "0123456789abcdef")
    assert_equal [], warnings.call("ANYTHING", nil)
  end

  test "values are encrypted at rest" do
    secret = @project.assign_secret(name: "STRIPE_SECRET_KEY", value: SECRET)
    secret.save!

    raw = ActionAgent::ProjectSecret.connection.select_value(
      "SELECT value FROM #{ActionAgent::ProjectSecret.quoted_table_name} WHERE id = #{secret.id.to_i}"
    )
    assert_not_includes raw, SECRET
    assert_equal SECRET, secret.reload.value
  end

  test "the boot spec carries the values in memory and records only their names" do
    @project.assign_secret(name: "STRIPE_SECRET_KEY", value: SECRET).save!

    spec = @project.boot_spec

    assert_equal({ "STRIPE_SECRET_KEY" => SECRET }, spec.secrets)
    assert_equal [ "STRIPE_SECRET_KEY" ], spec.redacted["secret_names"]
    assert_not_includes spec.redacted.to_json, "s3cret"
    assert_equal [ "/", true, "without_engine" ], [ spec.start_url, spec.keep_on_failure?, spec.apply ]
  end

  test "sign-in secrets stay out of the boot, and join the scrub lists by their credentials" do
    @project.assign_secret(name: "STRIPE_SECRET_KEY", value: SECRET).save!
    @project.assign_sign_in({ login_url: "/users/sign_in", login: "dev@example.com", password: "sign-in-password-123",
      password_field: "#user_password" }).save!
    cookies = [
      { "name" => "sid", "value" => "cookie-value-456", "domain" => "127.0.0.1", "path" => "/", "httpOnly" => true },
      { "name" => "remember", "value" => "remember-token-0123456789", "domain" => "127.0.0.1", "path" => "/" },
      { "name" => "consent", "value" => "accepted", "domain" => "127.0.0.1", "path" => "/" }
    ]
    stored = [ { "name" => "jwt", "value" => "eyJhbGciOiJIUzI1NiJ9.stored-token-789" }, { "name" => "menu", "value" => "expanded" } ]
    @project.assign_storage_state({ "cookies" => cookies, "origins" => [ { "origin" => "http://127.0.0.1:3000", "localStorage" => stored } ] }).save!

    assert_equal [ "STRIPE_SECRET_KEY" ], @project.boot_spec.secrets.keys
    assert_equal({ "login_url" => "/users/sign_in", "login" => "dev@example.com", "password" => "sign-in-password-123",
                   "password_field" => "#user_password" }, @project.secrets.sign_in.sole.sign_in_credentials)
    %w[sign-in-password-123 cookie-value-456 remember-token-0123456789 eyJhbGciOiJIUzI1NiJ9.stored-token-789].each do |value|
      assert_includes @project.scrub_values, value
    end
    %w[dev@example.com accepted expanded].each { |value| assert_not_includes @project.scrub_values, value }
    assert_equal "- button \"Menu\" [expanded]\n- text: Order accepted for dev@example.com",
      ActionAgent::SecretScrubber.scrub("- button \"Menu\" [expanded]\n- text: Order accepted for dev@example.com", @project.scrub_values)
    assert_equal [ "APP_SIGN_IN" ], @project.sign_in_secret_names
    assert_equal "cookie-value-456", @project.saved_storage_state.dig("cookies", 0, "value")
  end

  test "a sign-in keeps its password as typed, and a blank one keeps the saved password" do
    @project.assign_sign_in({ login_url: " /users/sign_in ", login: " dev@example.com ", password: " pa ss word " }).save!
    saved = @project.secrets.sign_in.sole.sign_in_credentials
    assert_equal [ "/users/sign_in", "dev@example.com", " pa ss word " ], saved.values_at("login_url", "login", "password")

    @project.assign_sign_in({ login_url: "/login", login: "qa@example.com", password: "" }).save!
    saved = @project.secrets.sign_in.sole.sign_in_credentials
    assert_equal [ "/login", "qa@example.com", " pa ss word " ], saved.values_at("login_url", "login", "password")

    @project.secrets.destroy_all
    assert_not @project.assign_sign_in({ login: "qa@example.com", password: "" }).valid?, "a first sign-in needs a password"
  end

  test "a secret's kind is fixed, and each kind's value is checked" do
    env = @project.assign_secret(name: "STRIPE_SECRET_KEY", value: SECRET)
    env.save!
    env.kind = "sign_in"
    assert_not env.valid?
    assert_includes env.errors[:kind].join, "cannot change"

    assert_not @project.assign_sign_in({ login: "dev@example.com" }).valid?, "a sign-in needs a password"
    assert_not @project.assign_sign_in({ password: "pw-0123456789", login_field: "a\nb" }).valid?
    assert_not @project.assign_storage_state({ "origins" => [] }).valid?, "a storage state needs a cookies list"
    long = { "cookies" => [ { "name" => "a", "value" => "x" * ActionAgent::ProjectSecret::MAX_STORAGE_STATE_LENGTH } ] }
    assert_not @project.assign_storage_state(long).valid?
    assert_equal [ "short_value" ], @project.assign_sign_in({ password: "short" }).warnings.map { |warning| warning[:code] }
    assert_equal "/", @project.assign_sign_in({ password: "pw-0123456789" }).sign_in_credentials["login_url"]
  end

  test "a value joins scrub lists with its URL-encoded and Base64 forms" do
    forms = ActionAgent::SecretScrubber.with_encodings([ SECRET, nil, "" ])

    [ SECRET, "sk_test_unit+s3cret%2Fvalue%2B0123", "sk_test_unit%20s3cret%2Fvalue%2B0123",
      [ SECRET ].pack("m0"), [ SECRET ].pack("m0").tr("+/", "-_") ].each { |form| assert_includes forms, form }
    assert_not_includes forms, ""
    text = "a #{SECRET} b #{[ SECRET ].pack("m0")} c #{ERB::Util.url_encode(SECRET)} d #{URI.encode_www_form_component(SECRET)}"
    assert_equal "a [REDACTED] b [REDACTED] c [REDACTED] d [REDACTED]", ActionAgent::SecretScrubber.scrub(text, forms)

    quoted = 'pa"ss\\word<1>'
    body = { user: { password: quoted } }
    [ JSON.generate(body), body.to_json ].each do |json|
      assert_equal '{"user":{"password":"[REDACTED]"}}', ActionAgent::SecretScrubber.scrub(json, ActionAgent::SecretScrubber.with_encodings([ quoted ]))
    end
  end

  test "a project's sandboxes and their code sessions are scrubbed of its secrets" do
    @project.assign_secret(name: "STRIPE_SECRET_KEY", value: SECRET).save!
    sandbox = checkout_sandbox(project: @project)
    other = checkout_sandbox

    assert_includes sandbox.project_scrub_values, SECRET
    assert_includes sandbox.project_scrub_values, [ SECRET ].pack("m0")
    assert_empty other.project_scrub_values

    session = ActionAgent::CodeSession.new(sandbox_session: sandbox, prompt: "Look around")
    assert_includes session.secrets, SECRET
    session.save!
    session.append_event!({ "type" => "assistant", "text" => "found #{SECRET} in .env" })
    assert_equal "found [REDACTED] in .env", session.reload.events.last["text"]
  end

  test "a sandbox on an install without the projects migration has nothing of a project's to scrub" do
    sandbox = checkout_sandbox
    sandbox.define_singleton_method(:has_attribute?) { |name| name.to_s != "project_id" && super(name) }
    sandbox.define_singleton_method(:project_id) { raise NoMethodError, "undefined method 'project_id'" }
    warned = []

    Rails.logger.stub(:warn, ->(message) { warned << message }) do
      assert_equal [], sandbox.project_scrub_values
    end
    assert_empty warned
  end

  test "an organization key is read when booting, and drops out of the scrub list once removed" do
    key = ActionAgent::ProviderKey.create!(provider: "anthropic", credential: "sk-ant-api03-organizationKey0123")
    secret = @project.assign_secret(name: "ANTHROPIC_API_KEY", source: "organization_key", consent: true)
    secret.save!

    assert_equal({ "ANTHROPIC_API_KEY" => key.credential }, @project.boot_spec.secrets)
    assert_includes @project.scrub_values, key.credential

    key.destroy!
    assert_empty @project.reload.scrub_values
  end

  test "a synced agent is one run_<slug> tool, not one of its actions' tools" do
    tools = [ { name: "run_support", description: "Ask support" }, { "name" => "run_billing-desk" }, { name: "run_support__triage" },
              { name: "lookup_order" }, { name: "run_" } ]

    assert_equal [ { slug: "support", tool: "run_support", description: "Ask support" },
                   { slug: "billing-desk", tool: "run_billing-desk", description: "" } ],
      ActionAgent::Project.synced_agents(tools)
  end

  private

  def checkout_sandbox(project: nil)
    sandbox = ActionAgent::SandboxSession.new(session_id: SecureRandom.uuid, sandbox_type: "app_runtime", repository: "acme/shop",
      project: project)
    sandbox.save!(validate: false)
    sandbox
  end
end
