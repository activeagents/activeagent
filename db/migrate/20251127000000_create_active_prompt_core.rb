# frozen_string_literal: true
class CreateActivePromptCore < ActiveRecord::Migration[7.0]
  def change
    create_table :active_prompt_prompts do |t|
      t.string  :name,        null: false
      t.text    :description
      t.json   :metadata,    null: false, default: {}
      t.text    :template
      t.timestamps
    end
    add_index :active_prompt_prompts, :name

    create_table :active_prompt_messages do |t|
      t.references :prompt,  null: false, foreign_key: { to_table: :active_prompt_prompts }
      t.string  :role,       null: false
      t.text    :content,    null: false
      t.integer :position
      t.json   :metadata,   null: false, default: {}
      t.timestamps
    end
    add_index :active_prompt_messages, [:prompt_id, :position]

    create_table :active_prompt_actions do |t|
      t.references :prompt,   null: false, foreign_key: { to_table: :active_prompt_prompts }
      t.string  :name,        null: false
      t.string  :tool_name
      t.json   :parameters,  null: false, default: {}
      t.json   :result,      null: false, default: {}
      t.string  :status
      t.timestamps
    end
    add_index :active_prompt_actions, [:prompt_id, :name]

    create_table :active_prompt_contexts do |t|
      t.string     :agent_type, null: false
      t.bigint     :agent_id,   null: false
      t.references :prompt,     null: false, foreign_key: { to_table: :active_prompt_prompts }
      t.string     :label
      t.json      :metadata,   null: false, default: {}
      t.timestamps
    end
    add_index :active_prompt_contexts, [:agent_type, :agent_id, :prompt_id], unique: true, name: "idx_ap_contexts_agent_prompt"
  end
end
