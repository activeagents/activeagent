require "test_helper"

class ScopedAgents::TranslationAgentWithCustomInstructionsTemplateTest < ActiveSupport::TestCase
  test "it uses instructions from custom_instructions template, embedding locales and an instance variable" do
    translate_prompt = ScopedAgents::TranslationAgentWithCustomInstructionsTemplate.with(
      message: "Hi, I'm Justin", locale: "japanese"
    ).translate

    assert_equal "# Custom Instructions\n\ntranslation additional instruction\nTranslate the given text from English to French.\n", translate_prompt.instructions
  end

  test "it uses overridden instructions for prompt" do
    translate_prompt = ScopedAgents::TranslationAgentWithCustomInstructionsTemplate.with(
      message: "Hi, I'm Justin", locale: "japanese"
    ).translate_with_overridden_instructions

    assert_equal "# Overridden Instructions\n\nTranslate the given text from one language to another.\n", translate_prompt.instructions
  end

  test "it does not include default system method `prompt_context` in action schemas" do
    translate_prompt = ScopedAgents::TranslationAgentWithCustomInstructionsTemplate.with(
      message: "Hi, I'm Justin", locale: "japanese"
    ).translate_with_overridden_instructions
    action_names = translate_prompt.actions.map { |a| a["function"]["name"] }

    refute_includes action_names, "prompt_context"
  end

  test "it returns action schemas for user methods except the called method translate_with_overridden_instructions" do
    translate_prompt = ScopedAgents::TranslationAgentWithCustomInstructionsTemplate.with(
      message: "Hi, I'm Justin", locale: "japanese"
    ).translate_with_overridden_instructions

    assert_equal 1, translate_prompt.actions.size
    assert_equal "translate", translate_prompt.actions[0]["function"]["name"]
  end

  test "it returns action schemas for user methods except the called method translate" do
    translate_prompt = ScopedAgents::TranslationAgentWithCustomInstructionsTemplate.with(
      message: "Hi, I'm Justin", locale: "japanese"
    ).translate

    assert_equal 1, translate_prompt.actions.size
    assert_equal "translate_with_overridden_instructions", translate_prompt.actions[0]["function"]["name"]
  end

  test "it returns action schemas for all user methods when prompt_context is called" do
    translate_prompt = ScopedAgents::TranslationAgentWithCustomInstructionsTemplate.with(
      message: "Hi, I'm Justin", locale: "japanese"
    ).prompt_context
    action_names = translate_prompt.actions.map { |a| a["function"]["name"] }

    assert_equal 2, translate_prompt.actions.size
    assert_includes action_names, "translate"
    assert_includes action_names, "translate_with_overridden_instructions"
  end
end
