# frozen_string_literal: true

class CreateActiveAgentSandboxRuns < ActiveRecord::Migration<%= migration_version %>
  def change
    create_table :active_agent_sandbox_runs do |t|
      t.references :sandbox_session, foreign_key: { to_table: :active_agent_sandbox_sessions }, null: true

      t.text :task, null: false
      t.integer :status, default: 0, null: false

      # Execution details
      t.text :result
      t.text :error
      t.integer :duration_ms
      t.integer :tokens_used
      t.datetime :started_at
      t.datetime :completed_at

      # Screenshots
      t.jsonb :screenshots, default: []

      t.timestamps
    end

    add_index :active_agent_sandbox_runs, :status
    add_index :active_agent_sandbox_runs, :created_at
  end
end
