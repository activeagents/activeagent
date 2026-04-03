# frozen_string_literal: true

class CreateActiveAgentTelemetryTraces < ActiveRecord::Migration<%= migration_version %>
  def change
    create_table :active_agent_telemetry_traces do |t|
<% if multi_tenant? -%>
      t.references :account, foreign_key: true, null: true
<% end -%>

      # Trace identification
      t.string :trace_id, null: false
      t.string :service_name
      t.string :environment

      # Timing
      t.datetime :timestamp, null: false

      # Span data (JSON array of spans)
      t.jsonb :spans, default: []

      # Resource attributes
      t.jsonb :resource_attributes, default: {}

      # SDK info
      t.jsonb :sdk_info, default: {}

      # Aggregated metrics (for quick queries)
      t.integer :total_duration_ms
      t.integer :total_input_tokens, default: 0
      t.integer :total_output_tokens, default: 0
      t.integer :total_thinking_tokens, default: 0

      # Status
      t.string :status, default: "UNSET"

      # Agent info (denormalized for queries)
      t.string :agent_class
      t.string :agent_action

      # Error info
      t.text :error_message

      t.timestamps
    end

    add_index :active_agent_telemetry_traces, :trace_id, unique: true
    add_index :active_agent_telemetry_traces, :timestamp
    add_index :active_agent_telemetry_traces, :service_name
    add_index :active_agent_telemetry_traces, :environment
    add_index :active_agent_telemetry_traces, :agent_class
    add_index :active_agent_telemetry_traces, :status
<% if multi_tenant? -%>
    add_index :active_agent_telemetry_traces, [:account_id, :timestamp]
<% end -%>
  end
end
