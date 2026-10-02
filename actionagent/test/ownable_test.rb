# frozen_string_literal: true

require "test_helper"

# A tenant model for the owner-class cases. The dummy app has users but no
# accounts, so the table is created here, as ReportTestAccount's is.
class OwnableTestAccount < ActiveRecord::Base
  def self.ensure_table!
    return if connection.table_exists?(:ownable_test_accounts)

    connection.create_table :ownable_test_accounts do |t|
      t.string :name
    end
  end
end
OwnableTestAccount.ensure_table!

# Ownable scoping and assignment when the owner handed in is not of the class
# the model is owned by. The user and the account tables share an id space,
# so every case below lines a user's id up with another tenant's id: an
# id-only scope would read that tenant's rows.
class OwnableTest < ActiveSupport::TestCase
  def setup
    ActionAgent::ProviderKey.delete_all
    ActionAgent::Agent.delete_all
    OwnableTestAccount.delete_all
    ActionAgent.multi_tenant = true
    ActionAgent.account_class = "OwnableTestAccount"
    ActionAgent.user_class = "User"

    @user = User.create!(name: "Member", email: "member-#{SecureRandom.hex(3)}@example.com", age: 30)
    @other = OwnableTestAccount.create!(id: @user.id, name: "Other tenant")
    @tenant = OwnableTestAccount.create!(id: @user.id + 1, name: "The user's tenant")
    @other_key = ActionAgent::ProviderKey.create!(provider: "openai", credential: "sk-other", account_id: @other.id)
    @tenant_key = ActionAgent::ProviderKey.create!(provider: "openai", credential: "sk-tenant", account_id: @tenant.id)
  end

  def teardown
    ActionAgent.tenant_resolver = nil
    ActionAgent.multi_tenant = false
    ActionAgent.account_class = nil
    ActionAgent.user_class = nil
  end

  def resolve_tenants!
    tenant = @tenant
    ActionAgent.tenant_resolver = ->(owner) { owner.is_a?(User) ? tenant : owner }
  end

  test "an account-owned model scopes to nothing for a user sharing another account's id" do
    assert_equal :account, ActionAgent::ProviderKey.owner_association
    assert_equal [ @other_key ], ActionAgent::ProviderKey.for_owner(@other).to_a
    assert_empty ActionAgent::ProviderKey.for_owner(@user),
      "a user is not an account, whatever account shares its id"
  end

  test "a user reads its tenant's rows when the host resolves tenants" do
    resolve_tenants!

    assert_equal [ @tenant_key ], ActionAgent::ProviderKey.for_owner(@user).to_a
  end

  test "a user-owned model scopes to nothing for an account" do
    agent = ActionAgent::Agent.create!(name: "Mine", provider: "openai", model: "gpt-4o-mini", user_id: @user.id)

    assert_equal :user, ActionAgent::Agent.owner_association
    assert_equal [ agent ], ActionAgent::Agent.for_owner(@user).to_a
    assert_empty ActionAgent::Agent.for_owner(@other)
  end

  test "an agent run falls back to no stored key when its owner is not an account" do
    agent = ActionAgent::Agent.create!(name: "Mine", provider: "openai", model: "gpt-4o-mini", user_id: @user.id)

    options = ActionAgent::AgentExecutionService.new(agent, nil).send(:owner_provider_options, "openai")

    assert_equal({}, options, "the account sharing the user's id must not supply the key")
  end

  test "an agent run reads its owner's tenant's stored key when the host resolves tenants" do
    resolve_tenants!
    agent = ActionAgent::Agent.create!(name: "Mine", provider: "openai", model: "gpt-4o-mini", user_id: @user.id)

    options = ActionAgent::AgentExecutionService.new(agent, nil).send(:owner_provider_options, "openai")

    assert_equal "sk-tenant", options[:access_token]
  end

  test "assigning an owner of another class raises rather than writing its id" do
    key = ActionAgent::ProviderKey.new(provider: "anthropic", credential: "sk-ant-api03-x")

    error = assert_raises(ArgumentError) { key.owner = @user }

    assert_match(/ProviderKey is owned by account \(OwnableTestAccount\), so a User cannot own it/, error.message)
    assert_nil key.account_id
  end

  test "assigning a user to an account-owned model assigns its tenant when the host resolves tenants" do
    resolve_tenants!
    key = ActionAgent::ProviderKey.new(provider: "anthropic", credential: "sk-ant-api03-x")

    key.owner = @user

    assert_equal @tenant.id, key.account_id
    assert_equal @tenant, key.owner
  end

  test "assigning the owner's own class and nil still work" do
    key = ActionAgent::ProviderKey.new(provider: "anthropic", credential: "sk-ant-api03-x")

    key.owner = @tenant
    assert_equal @tenant.id, key.account_id

    key.owner = nil
    assert_nil key.account_id
  end

  test "the trace scope matches the account by class" do
    traces = ActionAgent::TelemetryTrace

    assert_includes traces.for_account(@tenant).to_sql, %("account_id" = #{@tenant.id})
    assert_empty traces.for_account(@user), "a user is not an account"
    assert_empty traces.for_account(nil), "an unresolved tenant sees no traces"

    resolve_tenants!
    assert_includes traces.for_account(@user).to_sql, %("account_id" = #{@tenant.id})
  end

  test "the trace scope is every trace outside multi-tenant mode" do
    ActionAgent.multi_tenant = false

    assert_equal ActionAgent::TelemetryTrace.all.to_sql, ActionAgent::TelemetryTrace.for_account(@user).to_sql
  end
end
