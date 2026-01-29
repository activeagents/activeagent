# frozen_string_literal: true
require "test_helper"

class ActivePromptModelsTest < ActiveSupport::TestCase
  test "prompt with messages and actions persists" do
    p = ActivePrompt::Prompt.create!(name: "translate", description: "Translate text")
    p.messages.create!(role: :system,   content: "You translate.", position: 0)
    p.messages.create!(role: :user,     content: "Hello",          position: 1)
    p.actions.create!(name: "glossary_lookup", tool_name: "glossary", parameters: { term: "Hello" })

    assert_equal 2, p.messages.count
    assert_equal 1, p.actions.count
  end

  test "context attaches prompts to an agent" do
    # Use test-only AR model to avoid name collision with non-AR ApplicationAgent
    agent_class = ::PromptTestAgent

    agent  = agent_class.create!(name: "Translator", config: {})
    prompt = ActivePrompt::Prompt.create!(name: "translate")

    agent.add_prompt(prompt, label: "default")

    assert_equal [prompt.id], agent.prompts.pluck(:id)
    assert_equal 1, agent.prompt_contexts.count
  end

  test "engine models inherit from ActivePrompt::ApplicationRecord" do
    assert ActivePrompt::ApplicationRecord.abstract_class?, "ApplicationRecord should be abstract"
    assert_equal ActivePrompt::ApplicationRecord, ActivePrompt::Prompt.superclass
    assert_equal ActivePrompt::ApplicationRecord, ActivePrompt::Message.superclass
    assert_equal ActivePrompt::ApplicationRecord, ActivePrompt::Action.superclass
    assert_equal ActivePrompt::ApplicationRecord, ActivePrompt::Context.superclass
  end

  test "prompt to_runtime returns eager-loadable hashes" do
    prompt = ActivePrompt::Prompt.create!(name: "runtime")
    prompt.messages.create!(role: :system, content: "You are helpful", position: 0)
    prompt.actions.create!(name: "search", tool_name: "search", parameters: { q: "hello" })

    runtime = ActivePrompt::Prompt.with_runtime_associations.find(prompt.id).to_runtime

    assert_equal "runtime", runtime[:name]
    assert_equal 1, runtime[:messages].size
    assert_equal "You are helpful", runtime[:messages].first["content"]
    assert_equal 1, runtime[:actions].size
    assert_equal "search", runtime[:actions].first["name"]
    assert_equal({}, runtime[:metadata])
  end
end
