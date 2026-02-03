# frozen_string_literal: true
require "test_helper"

class ActivePromptValidationsTest < ActiveSupport::TestCase
  test "prompt requires name" do
    prompt = ActivePrompt::Prompt.new
    refute prompt.valid?
    assert_includes prompt.errors[:name], "can't be blank"
  end

  test "message requires role and content" do
    msg = ActivePrompt::Message.new
    refute msg.valid?
    assert_includes msg.errors[:role], "can't be blank"
    assert_includes msg.errors[:content], "can't be blank"
  end
end
