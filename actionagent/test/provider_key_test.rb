# frozen_string_literal: true

require "test_helper"

# The owner's saved keys as a hash, and written onto a config object through
# `<provider>_api_key=` writers — the shape a `RubyLLM.context` block hands
# out, without the engine depending on RubyLLM.
class ProviderKeyTest < ActiveSupport::TestCase
  # Any object with the writers will do; this one records what it was given.
  class Config
    attr_reader :applied

    def initialize
      @applied = {}
    end

    ActionAgent::ProviderKey::KEY_PROVIDERS.each do |provider|
      define_method(:"#{provider}_api_key=") { |value| @applied[provider] = value }
    end
  end

  def setup
    ActionAgent::ProviderKey.delete_all
    @previous_account_class = ActionAgent.account_class
    @previous_resolver = ActionAgent.provider_credentials_resolver
    ActionAgent.account_class = "User" # the dummy app has no Account
    @owner = User.create!(name: "Owner", email: "owner-#{SecureRandom.hex(4)}@example.com", age: 30)
    @other = User.create!(name: "Other", email: "other-#{SecureRandom.hex(4)}@example.com", age: 31)
  end

  def teardown
    ActionAgent::ProviderKey.delete_all
    ActionAgent.account_class = @previous_account_class
    ActionAgent.provider_credentials_resolver = @previous_resolver
    User.where(id: [ @owner.id, @other.id ]).delete_all
  end

  test "credentials_for returns the owner's API keys by provider, and only API keys" do
    create_key("openai", "sk-openai-owner", owner: @owner)
    create_key("anthropic", "sk-ant-owner", owner: @owner)
    create_key("ollama", "http://localhost:11434", owner: @owner)
    create_key("openai", "sk-openai-other", owner: @other)

    assert_equal({ "anthropic" => "sk-ant-owner", "openai" => "sk-openai-owner" },
      ActionAgent::ProviderKey.credentials_for(@owner))
  end

  test "credentials_for is empty for an owner with no keys and for an unresolved owner" do
    create_key("openai", "sk-openai-owner", owner: @owner)

    assert_equal({}, ActionAgent::ProviderKey.credentials_for(@other))
    assert_equal({}, ActionAgent::ProviderKey.credentials_for(nil),
      "a nil owner on an install with an owner model must not see every owner's keys")
  end

  test "credentials_for skips a credential that cannot be decrypted and names only the error class" do
    create_key("anthropic", "sk-ant-owner", owner: @owner)
    stale = create_key("openai", "sk-openai-stale", owner: @owner)
    corrupt_stored_credential(stale)

    log = StringIO.new
    credentials = with_logger(Logger.new(log)) { ActionAgent::ProviderKey.credentials_for(@owner) }

    assert_equal({ "anthropic" => "sk-ant-owner" }, credentials)
    assert_match(/\[ProviderKey\] skipping openai credential ##{stale.id}: ActiveRecord::Encryption::Errors::Decryption/,
      log.string)
    assert_no_match(/sk-openai-stale|not-ciphertext/, log.string, "the warning must never carry a credential")
  end

  # Rows are scoped by the owner's id alone, so an instance of another model
  # would read whichever owner happens to share its id.
  test "credentials_for refuses an owner that is not the install's owner model" do
    create_key("openai", "sk-openai-owner", owner: @owner)
    impostor = Struct.new(:id).new(@owner.id)

    error = assert_raises(ArgumentError) { ActionAgent::ProviderKey.credentials_for(impostor) }
    assert_match(/per account \(User\)/, error.message)
    assert_raises(ArgumentError) { ActionAgent::ProviderKey.apply_to(Config.new, owner: impostor) }
  end

  test "credentials_for takes the host's credential resolver first, as the engine's runs do" do
    create_key("openai", "sk-openai-row", owner: @owner)
    create_key("anthropic", "sk-ant-row", owner: @owner)
    create_key("openrouter", "sk-or-row", owner: @owner)
    asked = []
    ActionAgent.provider_credentials_resolver = lambda do |owner, provider|
      asked << [ owner, provider ]
      case provider
      when "openai" then { access_token: "sk-openai-vault" }
      when "openrouter" then { "uri_base" => "https://proxy.example.com" } # an answer with no key
      end
    end

    assert_equal({ "anthropic" => "sk-ant-row", "openai" => "sk-openai-vault" },
      ActionAgent::ProviderKey.credentials_for(@owner),
      "a resolver answer without a key leaves the provider to the host's own configuration")
    assert_equal ActionAgent::ProviderKey::KEY_PROVIDERS.sort, asked.map(&:last)
    assert(asked.all? { |owner, _| owner == @owner })
  end

  # A gateway's key belongs to the gateway: paired with the public endpoint a
  # RubyLLM config defaults to, it would be sent somewhere it was not meant for.
  test "credentials_for leaves out a provider the resolver sends to another endpoint" do
    create_key("openai", "sk-openai-row", owner: @owner)
    ActionAgent.provider_credentials_resolver = lambda do |_owner, provider|
      { access_token: "sk-gateway", uri_base: "https://gateway.example.com/v1" } if provider == "openai"
    end

    assert_equal({}, ActionAgent::ProviderKey.credentials_for(@owner))
  end

  test "credentials_for reads a resolver's key as the providers do: api_key, then access_token, blanks skipped" do
    ActionAgent.provider_credentials_resolver = lambda do |_owner, provider|
      case provider
      when "openai" then { "access_token" => "", "api_key" => "sk-openai-api" }
      when "anthropic" then { access_token: "sk-ant-token", api_key: "sk-ant-api" }
      when "openrouter" then "not a hash"
      end
    end

    assert_equal({ "anthropic" => "sk-ant-api", "openai" => "sk-openai-api" },
      ActionAgent::ProviderKey.credentials_for(@owner))
  end

  test "credentials_for sees through a delegating decorator" do
    create_key("openai", "sk-openai-owner", owner: @owner)

    assert_equal({ "openai" => "sk-openai-owner" }, ActionAgent::ProviderKey.credentials_for(SimpleDelegator.new(@owner)))
  end

  test "credentials_for refuses every owner when the owner class does not load" do
    ActionAgent.account_class = "NoSuchOwnerModel"

    assert_raises(ArgumentError) { ActionAgent::ProviderKey.credentials_for(@owner) }
  end

  test "apply_to writes each key through the config's provider writer and returns only provider names" do
    create_key("openai", "sk-openai-owner", owner: @owner)
    create_key("openrouter", "sk-or-owner", owner: @owner)
    create_key("ollama", "http://localhost:11434", owner: @owner)
    config = Config.new

    applied = ActionAgent::ProviderKey.apply_to(config, owner: @owner)

    assert_equal({ "openai" => "sk-openai-owner", "openrouter" => "sk-or-owner" }, config.applied)
    assert_equal %w[openai openrouter], applied, "the return value is safe to log: it carries no key"
  end

  test "apply_to touches nothing for an owner without keys" do
    config = Config.new

    ActionAgent::ProviderKey.apply_to(config, owner: @owner)

    assert_empty config.applied
  end

  private

  def create_key(provider, credential, owner:)
    ActionAgent::ProviderKey.create!(provider: provider, credential: credential, owner: owner)
  end

  # Overwrite the stored ciphertext behind the model's back, the way a row
  # encrypted under a key the app no longer has reads.
  def corrupt_stored_credential(key)
    connection = ActionAgent::ProviderKey.connection
    connection.update(
      "UPDATE #{connection.quote_table_name(ActionAgent::ProviderKey.table_name)} " \
      "SET credential = #{connection.quote('not-ciphertext')} WHERE id = #{connection.quote(key.id)}"
    )
  end

  def with_logger(logger)
    previous = Rails.logger
    Rails.logger = logger
    yield
  ensure
    Rails.logger = previous
  end
end
