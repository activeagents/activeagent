# frozen_string_literal: true
module ActivePrompt
  class Prompt < ApplicationRecord
    self.table_name = "active_prompt_prompts"

    has_many :messages, class_name: "ActivePrompt::Message", dependent: :destroy, inverse_of: :prompt
    has_many :actions,  class_name: "ActivePrompt::Action",  dependent: :destroy, inverse_of: :prompt

    has_many :contexts, class_name: "ActivePrompt::Context", dependent: :destroy, inverse_of: :prompt
    has_many :agents, through: :contexts, source: :agent

    validates :name, presence: true

    def to_runtime
      {
        name: name,
        description: description,
        template: template,
        messages: messages.order(:position).map(&:attributes),
        actions: actions.map(&:attributes),
        metadata: metadata || {}
      }
    end
  end
end
