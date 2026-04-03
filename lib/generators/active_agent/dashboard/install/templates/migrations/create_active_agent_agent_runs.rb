# frozen_string_literal: true

class CreateActiveAgentAgentRuns < ActiveRecord::Migration<%= migration_version %>
  def change
    create_table :active_agent_agent_runs do |t|
      t.references :agent, null: false, foreign_key: { to_table: :active_agent_agents }

      # Input
      t.text :input_prompt
      t.jsonb :input_params, default: {}

      # Output
      t.text :output
      t.jsonb :output_metadata, default: {}

      # Execution details
      t.integer :status, default: 0, null: false
      t.integer :duration_ms
      t.datetime :started_at
      t.datetime :completed_at

      # Token usage
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :total_tokens

      # Error tracking
      t.text :error_message
      t.text :error_backtrace

      # Trace for debugging
      t.string :trace_id
      t.jsonb :logs, default: []

      t.timestamps
    end

    add_index :active_agent_agent_runs, :status
    add_index :active_agent_agent_runs, :trace_id
    add_index :active_agent_agent_runs, :created_at
  end
end
