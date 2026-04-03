# frozen_string_literal: true

class CreateActiveAgentAgents < ActiveRecord::Migration<%= migration_version %>
  def change
    create_table :active_agent_agents do |t|
      t.string :name, null: false
      t.text :description
      t.string :slug, null: false

      # Agent class configuration
      t.string :agent_class_name
      t.string :provider, default: "openai"
      t.string :model, default: "gpt-4o-mini"

      # Instructions and system prompt
      t.text :instructions

      # Avatar/appearance configuration
      t.string :preset_type
      t.jsonb :appearance, default: {}

      # Capabilities
      t.jsonb :instruction_sets, default: []
      t.jsonb :tools, default: []
      t.jsonb :mcp_servers, default: []

      # Model configuration
      t.jsonb :model_config, default: {}

      # Response format
      t.jsonb :response_format, default: {}

      # Status
      t.integer :status, default: 0, null: false

      # Owner associations (optional)
      t.references :user, foreign_key: true, null: true
<% if multi_tenant? -%>
      t.references :account, foreign_key: true, null: true
<% end -%>

      t.timestamps
    end

<% if multi_tenant? -%>
    add_index :active_agent_agents, [:account_id, :slug], unique: true
<% else -%>
    add_index :active_agent_agents, [:user_id, :slug], unique: true
<% end -%>
    add_index :active_agent_agents, :status
    add_index :active_agent_agents, :provider
  end
end
