# frozen_string_literal: true

# The trace store the engine's install generator writes (single-tenant
# shape). The reference host had every dashboard table but this one, so any
# view that joins runs with reported traces — the agent's runs list, for
# one — raised on a missing table.
class CreateActiveAgentTelemetryTraces < ActiveRecord::Migration[7.2]
  def change
    create_table :active_agent_telemetry_traces do |t|
      t.string :trace_id, null: false
      t.string :service_name
      t.string :environment
      t.datetime :timestamp, index: true
      t.json :spans, default: []
      t.json :resource_attributes, default: {}
      t.json :sdk_info, default: {}
      t.decimal :total_duration_ms, precision: 12, scale: 3
      t.integer :total_input_tokens, default: 0
      t.integer :total_output_tokens, default: 0
      t.integer :total_thinking_tokens, default: 0
      t.string :status
      t.string :agent_class, index: true
      t.string :agent_action
      t.bigint :agent_id, index: true
      t.text :error_message

      t.timestamps
    end

    add_index :active_agent_telemetry_traces, :trace_id, unique: true
    add_index :active_agent_telemetry_traces, :status
    add_index :active_agent_telemetry_traces, [ :agent_class, :agent_action ]
    add_index :active_agent_telemetry_traces, [ :service_name, :environment ]
    add_index :active_agent_telemetry_traces, :created_at
  end
end
