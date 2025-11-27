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
end
