# frozen_string_literal: true
module ActivePrompt
  class Message < ApplicationRecord
    self.table_name = "active_prompt_messages"

    belongs_to :prompt, class_name: "ActivePrompt::Prompt", inverse_of: :messages

    enum :role, { system: "system", user: "user", assistant: "assistant", tool: "tool" }, prefix: true
    validates :role, :content, presence: true
  end
end
