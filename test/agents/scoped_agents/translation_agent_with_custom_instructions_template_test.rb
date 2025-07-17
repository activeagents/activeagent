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
end
