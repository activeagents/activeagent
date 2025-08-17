require "test_helper"

class DataCollectionOverrideTest < ActiveSupport::TestCase
  test "runtime data_collection overrides configuration" do
    # Create an agent with default "allow" configuration
    agent_class = Class.new(ApplicationAgent) do
      generate_with :open_router,
        model: "openai/gpt-4o-mini"
    end

    agent = agent_class.new
    provider = agent.send(:generation_provider)

    # Verify it's an OpenRouter provider
    assert_kind_of ActiveAgent::GenerationProvider::OpenRouterProvider, provider

    # Create a prompt with runtime override to "deny"
    prompt_context = agent.prompt(
      message: "test message",
      options: { data_collection: "deny" }
    )

    # Set the prompt on the provider
    provider.instance_variable_set(:@prompt, prompt_context)

    # Verify runtime override takes precedence
    prefs = provider.send(:build_provider_preferences)
    assert_equal "deny", prefs[:data_collection]
  end

  test "runtime data_collection with selective providers" do
    # Create an agent with "deny" configuration
    agent_class = Class.new(ApplicationAgent) do
      generate_with :open_router,
        model: "openai/gpt-4o-mini",
        data_collection: "deny"
    end

    agent = agent_class.new
    provider = agent.send(:generation_provider)

    # Create a prompt with runtime override to selective providers
    prompt_context = agent.prompt(
      message: "test message",
      options: { data_collection: [ "OpenAI", "Google" ] }
    )

    # Set the prompt on the provider
    provider.instance_variable_set(:@prompt, prompt_context)

    # Verify runtime override with array of providers
    prefs = provider.send(:build_provider_preferences)
    assert_equal [ "OpenAI", "Google" ], prefs[:data_collection]
  end

  test "no runtime override uses configured value" do
    # Create an agent with "deny" configuration
    agent_class = Class.new(ApplicationAgent) do
      generate_with :open_router,
        model: "openai/gpt-4o-mini",
        data_collection: "deny"
    end

    agent = agent_class.new
    provider = agent.send(:generation_provider)

    # Create a prompt without data_collection override
    prompt_context = agent.prompt(message: "test message")

    # Set the prompt on the provider
    provider.instance_variable_set(:@prompt, prompt_context)

    # Verify configured value is used
    prefs = provider.send(:build_provider_preferences)
    assert_equal "deny", prefs[:data_collection]
  end
end
