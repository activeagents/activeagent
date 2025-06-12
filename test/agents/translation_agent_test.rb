require "test_helper"

class TranslationAgentTest < ActiveSupport::TestCase
  test "it renders a translate prompt and generates a translation" do
    VCR.use_cassette("translation_agent_direct_prompt_generation") do
      response = TranslationAgent.with(message: "Hi, I'm Justin", locale: "japanese").translate.generate_now
      assert_equal "こんにちは、私はジャスティンです。", response.message.content
    end
  end
end
