# frozen_string_literal: true
require "test_helper"

class ActivePromptOrderingTest < ActiveSupport::TestCase
  test "messages return in position order via to_runtime" do
    p = ActivePrompt::Prompt.create!(name: "ordered")
    p.messages.create!(role: :user, content: "B", position: 2)
    p.messages.create!(role: :system, content: "A", position: 1)
    order = p.to_runtime[:messages].map { |m| m["content"] }
    assert_equal %w[A B], order
  end
end
