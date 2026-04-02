# frozen_string_literal: true

class CreateActiveAgentAgentTemplates < ActiveRecord::Migration<%= migration_version %>
  def change
    create_table :active_agent_agent_templates do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description
      t.string :category

      # Template configuration (same as agents)
      t.string :provider, default: "openai"
      t.string :model, default: "gpt-4o-mini"
      t.text :instructions
      t.string :preset_type
      t.jsonb :appearance, default: {}
      t.jsonb :instruction_sets, default: []
      t.jsonb :tools, default: []
      t.jsonb :mcp_servers, default: {}
      t.jsonb :model_config, default: {}

      # Metadata
      t.string :icon
      t.integer :usage_count, default: 0
      t.boolean :featured, default: false
      t.boolean :public, default: true
      t.boolean :free_tier, default: true

      t.timestamps
    end

    add_index :active_agent_agent_templates, :slug, unique: true
    add_index :active_agent_agent_templates, :category
    add_index :active_agent_agent_templates, :featured
    add_index :active_agent_agent_templates, :usage_count
    add_index :active_agent_agent_templates, :free_tier
  end
end
