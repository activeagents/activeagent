# frozen_string_literal: true
module ActivePrompt
  class Action < ApplicationRecord
    self.table_name = "active_prompt_actions"

    belongs_to :prompt, class_name: "ActivePrompt::Prompt", inverse_of: :actions

    validates :name, presence: true
  end
end
