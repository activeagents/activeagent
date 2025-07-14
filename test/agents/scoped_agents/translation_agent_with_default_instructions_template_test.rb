require "test_helper"

class ScopedAgents::TranslationAgentWithDefaultInstructionsTemplateTest < ActiveSupport::TestCase
  test "it uses instructions from default instructions template" do
    translate_prompt = ScopedAgents::TranslationAgentWithDefaultInstructionsTemplate.with(
      message: "Hi, I'm Justin", locale: "japanese"
    ).translate

    assert_equal "# Default Instructions\n\nTranslate the given text from one language to another.\n", translate_prompt.instructions
  end
end
