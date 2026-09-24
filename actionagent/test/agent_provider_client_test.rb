# frozen_string_literal: true

require "test_helper"

# Provider client gems are optional, so an agent is refused a provider whose
# gem the host never installed when the provider is chosen, not on its first
# run (#416).
class AgentProviderClientTest < ActiveSupport::TestCase
  def setup
    ActionAgent::Agent.delete_all
  end

  MISSING_OPENAI = lambda do |_service|
    raise LoadError, "The 'openai' gem is required for OpenRouterProvider. " \
      "Please add it to your Gemfile and run `bundle install`."
  end

  test "a provider whose client gem is installed is accepted" do
    agent = ActionAgent::Agent.new(name: "Router", provider: "openrouter", model: "openai/gpt-4o-mini")

    assert agent.valid?, agent.errors.full_messages.to_sentence
  end

  test "a provider whose client gem is missing is refused, naming the gem" do
    agent = ActionAgent::Agent.new(name: "Router", provider: "openrouter", model: "openai/gpt-4o-mini")

    ActiveAgent::Base.stub(:provider_load, MISSING_OPENAI) do
      assert_not agent.valid?
    end
    assert_match(/openrouter can't be used yet: The 'openai' gem is required/, agent.errors[:provider].first)
  end

  test "an agent keeping its provider is not rechecked" do
    agent = ActionAgent::Agent.create!(name: "Router", provider: "openrouter", model: "openai/gpt-4o-mini")

    ActiveAgent::Base.stub(:provider_load, MISSING_OPENAI) do
      assert agent.update(description: "Routes models")
    end
  end
end
