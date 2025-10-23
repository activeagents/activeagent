require "test_helper"

class TranslationAgentTest < ActiveSupport::TestCase
  test "it renders a translate action prompt with a message" do
    # region translation_agent_render_translate_prompt
    translate_prompt = TranslationAgent.with(message: "Hi, I'm Justin", locale: "japanese").translate

    assert_equal "translate: Hi, I'm Justin; to japanese\n", translate_prompt.message.content
    assert_equal "Translate the given text from one language to another.", translate_prompt.instructions
    # endregion translation_agent_render_translate_prompt
  end

  test "it renders a translate prompt and generates a translation" do
    VCR.use_cassette("translation_agent_direct_prompt_generation") do
      # region translation_agent_translate_prompt_generation
      response = TranslationAgent.with(
        message: "Hi, I'm Justin",
        locale: "japanese"
      ).translate.generate_now
      assert_equal "こんにちは、私はジャスティンです。", response.message.content
      # endregion translation_agent_translate_prompt_generation

      doc_example_output(response)
    end
  end
end
