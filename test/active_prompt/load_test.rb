# frozen_string_literal: true
require "test_helper"

class ActivePromptLoadTest < ActiveSupport::TestCase
  test "requiring top-level file doesn't error" do
    assert_nothing_raised do
      require "active_prompt"
    end
  end
end
