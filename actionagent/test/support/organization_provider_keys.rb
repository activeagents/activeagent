# frozen_string_literal: true

# A multi-tenant install whose account shares organization keys with its
# members: an account, two members (Ada, signed in, and Grace), an
# organization Anthropic key and a personal Anthropic key for each member.
# The dummy app has no Account model, so the account is a User, as in the
# other multi-tenant tests.
module OrganizationProviderKeys
  ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
  OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"

  def setup
    super
    ActionAgent::ProviderKey.delete_all
    ActionAgent::Agent.delete_all
    ActionAgent::SandboxSession.delete_all
    ActionAgent.user_class = "User"
    ActionAgent.account_class = "User"
    ActionAgent.multi_tenant = true

    @account = user("Acme")
    @ada = user("Ada")
    @grace = user("Grace")
    @signed_in = @ada
    ActionAgent.current_account_resolver = ->(_controller) { @account }
    ActionAgent.current_user_resolver = ->(_controller) { @signed_in }

    @organization_key = key("anthropic", "sk-ant-organization")
    @ada_key = key("anthropic", "sk-ant-ada", member: @ada)
    @grace_key = key("anthropic", "sk-ant-grace", member: @grace)
  end

  def teardown
    ActionAgent.multi_tenant = false
    ActionAgent.user_class = nil
    ActionAgent.account_class = nil
    ActionAgent.current_account_resolver = nil
    ActionAgent.current_user_resolver = nil
    ActionAgent.provider_credentials_resolver = nil
    ActionAgent.provider_key_scope = :organization
    ActionAgent.permission_checker = nil
    ActionAgent.members_resolver = nil
    ActionAgent.member_invite_url = nil
    super
  end

  private

  def user(name)
    User.create!(name: name, email: "#{name.downcase}-#{SecureRandom.hex(3)}@example.com", age: 30)
  end

  def key(provider, credential, member: nil, api_key: nil)
    ActionAgent::ProviderKey.create!(
      provider: provider, credential: credential, api_key: api_key, account_id: @account.id,
      scope_key: member ? "user:#{member.id}" : "organization"
    )
  end

  def resolve(actor:, owner: @account, provider: "anthropic")
    ActionAgent::ProviderCredentials.resolve(owner: owner, actor: actor, provider: provider)
  end

  def assert_resolution(source, access_token, actor:, message: nil)
    resolution = resolve(actor: actor)
    assert_equal [ source, access_token ], [ resolution.source, resolution.options[:access_token] ], message
  end

  def provider_row(provider)
    response.parsed_body["provider_keys"].find { |row| row["provider"] == provider }
  end

  def anthropic_agent
    ActionAgent::Agent.create!(name: "Support", provider: "anthropic", model: "claude-haiku-4-5",
                               instructions: "Be brief.", user_id: @account.id)
  end

  def anthropic_reply(text = "Hello.")
    { status: 200, headers: { "Content-Type" => "application/json" }, body: {
      id: "msg_fixture", type: "message", role: "assistant", model: "claude-haiku-4-5",
      content: [ { type: "text", text: text } ], stop_reason: "end_turn", stop_sequence: nil,
      usage: { input_tokens: 5, output_tokens: 5 }
    }.to_json }
  end

  def with_provider_config(config)
    original = ActiveAgent.configuration
    ActiveAgent.instance_variable_set(:@configuration, config)
    yield
  ensure
    ActiveAgent.instance_variable_set(:@configuration, original)
  end

  def with_env(values)
    previous = values.keys.to_h { |name| [ name, ENV[name] ] }
    values.each { |name, value| ENV[name] = value }
    yield
  ensure
    previous.each { |name, value| ENV[name] = value }
  end
end
