# frozen_string_literal: true

class CreateActiveAgentSessionRecordings < ActiveRecord::Migration<%= migration_version %>
  def change
    create_table :active_agent_session_recordings do |t|
      t.references :agent_run, null: true, foreign_key: { to_table: :active_agent_agent_runs }
      t.references :sandbox_session, null: true, foreign_key: { to_table: :active_agent_sandbox_sessions }
      t.string :name
      t.integer :status, default: 0, null: false
      t.integer :duration_ms
      t.integer :action_count, default: 0
      t.jsonb :metadata, default: {}
      t.timestamps
    end

    create_table :active_agent_recording_actions do |t|
      t.references :session_recording, null: false, foreign_key: { to_table: :active_agent_session_recordings }
      t.string :action_type, null: false
      t.integer :sequence, null: false
      t.integer :timestamp_ms, null: false
      t.string :selector
      t.text :value
      t.string :screenshot_key
      t.string :dom_snapshot_key
      t.jsonb :metadata, default: {}
      t.timestamps
    end

    add_index :active_agent_recording_actions, [:session_recording_id, :sequence], unique: true, name: "idx_recording_actions_on_recording_and_sequence"

    create_table :active_agent_recording_snapshots do |t|
      t.references :session_recording, null: false, foreign_key: { to_table: :active_agent_session_recordings }
      t.references :recording_action, null: true, foreign_key: { to_table: :active_agent_recording_actions }
      t.string :storage_key, null: false
      t.string :snapshot_type, null: false
      t.integer :width
      t.integer :height
      t.integer :file_size_bytes
      t.timestamps
    end

    add_index :active_agent_recording_snapshots, :storage_key, unique: true
  end
end
