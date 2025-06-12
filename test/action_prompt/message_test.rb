require "test_helper"

module ActiveAgent
  module ActionPrompt
    class MessageTest < ActiveSupport::TestCase
      test "array for message hashes to messages" do
        messages = [
          { content: "Instructions", role: :system },
          { content: "This is a message", role: :user }
        ]
        assert Message.from_messages(messages).first.is_a? Message
      end
    end
  end
end
