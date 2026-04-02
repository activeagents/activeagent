# frozen_string_literal: true

class CreateActiveAgentSandboxSessions < ActiveRecord::Migration<%= migration_version %>
  def change
    create_table :active_agent_sandbox_sessions do |t|
      t.string :session_id, null: false
      t.references :user, foreign_key: true, null: true
<% if multi_tenant? -%>
      t.references :account, foreign_key: true, null: true
<% end -%>
      t.references :agent_template, foreign_key: { to_table: :active_agent_agent_templates }, null: true

      # Session metadata
      t.string :sandbox_type, default: "playwright_mcp"
      t.integer :status, default: 0
      t.string :cloud_run_job_id
      t.string :cloud_run_url

      # Execution tracking
      t.integer :runs_count, default: 0
      t.integer :max_runs, default: 10
      t.integer :timeout_seconds, default: 300
      t.datetime :expires_at
      t.datetime :last_activity_at

      # Resource usage
      t.integer :total_tokens, default: 0
      t.integer :total_duration_ms, default: 0

      # Results
      t.jsonb :runs, default: []
      t.text :error_message

      t.timestamps
    end

    add_index :active_agent_sandbox_sessions, :session_id, unique: true
    add_index :active_agent_sandbox_sessions, :status
    add_index :active_agent_sandbox_sessions, :sandbox_type
    add_index :active_agent_sandbox_sessions, :expires_at
    add_index :active_agent_sandbox_sessions, :cloud_run_job_id
  end
end
