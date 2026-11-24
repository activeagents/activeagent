# frozen_string_literal: true

class CreateActiveAgentTelemetryTraces < ActiveRecord::Migration[8.1]
  def change
    create_table :active_agent_telemetry_traces do |t|
      t.string :trace_id, null: false
      t.string :service_name
      t.string :environment
      t.datetime :timestamp, index: true
      t.column :spans, json_type, **json_default([])
      t.column :resource_attributes, json_type, **json_default({})
      t.column :sdk_info, json_type, **json_default({})
      t.decimal :total_duration_ms, precision: 12, scale: 3
      t.integer :total_input_tokens, default: 0
      t.integer :total_output_tokens, default: 0
      t.integer :total_thinking_tokens, default: 0
      t.string :status
      t.string :agent_class, index: true
      t.string :agent_action
      # Set on ingest when the trace can be attributed to a dashboard agent;
      # nullable because a trace must still land when it cannot be.
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

  private

  # jsonb where the adapter has it, json where it doesn't. The dashboard
  # traverses spans in SQL on PostgreSQL, and jsonb_array_elements rejects a
  # json argument, so the column type and the query have to agree.
  def json_type
    @json_type ||= postgres? ? :jsonb : :json
  end

  # MySQL rejects a default on a JSON column outright ("BLOB, TEXT, GEOMETRY or
  # JSON column can't have a default value"), which aborts create_table, so the
  # column is created without one there. ActionAgent::TelemetryTrace reads every
  # JSON column through `Array(...)`/`|| {}`, and ingest always assigns all
  # three, so a NULL reads the same as the empty default would.
  def json_default(value)
    postgres? ? { default: value } : {}
  end

  def postgres?
    connection.adapter_name.to_s.downcase.include?("postgres")
  end
end
