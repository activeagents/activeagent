# frozen_string_literal: true

# Claude Code sessions run inside an app_runtime sandbox's checkout: the
# prompt, the scrubbed stream-json transcript, the reported outcome and the
# resulting diff. Emitted alongside the dashboard tables on a fresh install,
# and on its own for an install that predates it.
#
# Table names follow ActionAgent.table_name_prefix, and JSON columns are
# jsonb on PostgreSQL and json elsewhere, the same way as
# create_active_agent_dashboard_tables.
class CreateActiveAgentCodeSessions < ActiveRecord::Migration[7.2]
  def change
    prefix = ActionAgent.table_name_prefix

    create_table "#{prefix}code_sessions" do |t|
      t.bigint :sandbox_session_id, null: false
      t.text :prompt, null: false
      t.integer :status, default: 0, null: false
      t.column :events, json_type, **json_default([])
      t.integer :dropped_events_count, default: 0, null: false
      t.text :result
      t.text :diff
      t.text :error_message
      t.string :model
      t.string :claude_session_id
      t.integer :num_turns
      t.integer :duration_ms
      t.decimal :total_cost_usd, precision: 12, scale: 6
      t.integer :input_tokens
      t.integer :output_tokens
      t.datetime :started_at
      t.datetime :finished_at
      t.bigint :user_id
      t.bigint :account_id
      t.timestamps
      t.index :sandbox_session_id
      t.index :user_id
      t.index :account_id
    end
  end

  private

  def json_type
    @json_type ||= postgres? ? :jsonb : :json
  end

  # MySQL rejects a default on a JSON column outright, so the column is
  # created without one there.
  def json_default(value, null: nil)
    return {} unless postgres?

    null.nil? ? { default: value } : { default: value, null: null }
  end

  def postgres?
    connection.adapter_name.to_s.downcase.include?("postgres")
  end
end
