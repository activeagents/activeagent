# frozen_string_literal: true
module ActivePrompt
  # Polymorphic join: attach prompts to any agent record
  class Context < ApplicationRecord
    self.table_name = "active_prompt_contexts"

    belongs_to :agent,  polymorphic: true, inverse_of: :prompt_contexts
    belongs_to :prompt, class_name: "ActivePrompt::Prompt", inverse_of: :contexts

    validates :agent, :prompt, presence: true
    validates :label, length: { maximum: 255 }, allow_nil: true
  end
end
