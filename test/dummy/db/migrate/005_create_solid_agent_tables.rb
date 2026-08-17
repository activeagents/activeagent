# frozen_string_literal: true

# The tables `rails generate solid_agent:install` writes into a host app.
#
# Deliberately unprefixed: migration 004 creates the dashboard engine's own
# copy of this schema under ActionAgent.table_name_prefix ("active_agent_"),
# which the engine owns and namespaces. These are the host-app tables an
# ordinary Rails app gets, and what test/integration/solid_agent exercises —
# the combination a user actually installs.
#
# Kept in step with solid_agent's generator templates in
# lib/generators/solid_agent/install/templates.
class CreateSolidAgentTables < ActiveRecord::Migration[7.2]
  def change
    create_table :agent_contexts do |t|
      t.references :contextable, polymorphic: true, index: true
      t.string :agent_name, null: false
      t.string :action_name, null: false
      t.text :instructions
      t.column :options, json_type, default: {}
      t.string :trace_id, index: true
      t.integer :total_input_tokens, default: 0
      t.integer :total_output_tokens, default: 0
      t.timestamps
      t.index [ :agent_name, :action_name ]
    end

    create_table :agent_messages do |t|
      t.references :agent_context, null: false, foreign_key: true, index: true
      t.string :role, null: false
      t.text :content
      t.string :tool_call_id
      t.string :tool_name
      t.column :tool_arguments, json_type, default: {}
      t.column :tool_result, json_type
      t.column :attachments, json_type, default: []
      t.column :metadata, json_type, default: {}
      t.column :provenance, json_type, default: {}
      t.string :content_checksum
      t.timestamps
      t.index :role
      t.index :tool_call_id
    end

    create_table :agent_generations do |t|
      t.references :agent_context, null: false, foreign_key: true, index: true
      t.text :content
      t.string :model
      t.string :provider
      t.string :finish_reason
      t.integer :input_tokens, default: 0
      t.integer :output_tokens, default: 0
      t.integer :cached_tokens, default: 0
      t.integer :reasoning_tokens, default: 0
      t.column :tool_calls, json_type, default: []
      t.column :raw_response, json_type
      t.float :duration_seconds
      t.string :trace_id, index: true
      t.column :provenance, json_type, default: {}
      t.timestamps
    end

    create_table :agent_memories do |t|
      t.references :memorable, polymorphic: true, index: true
      t.string :scope, null: false, default: "default"
      t.timestamps
      t.index [ :memorable_type, :memorable_id, :scope ], unique: true,
        name: "index_agent_memories_on_memorable_and_scope"
    end

    create_table :agent_memory_entries do |t|
      t.references :agent_memory, null: false, foreign_key: true
      t.text :content, null: false
      t.string :source_agent
      t.string :category
      t.timestamps
      t.index :category
    end

    create_table :agent_runs do |t|
      t.references :runnable, polymorphic: true, index: true
      t.string :agent_name
      t.string :action_name
      t.string :trace_id, index: true
      t.string :status, null: false, default: "pending"
      t.text :input_prompt
      t.column :input_params, json_type, default: {}
      t.text :output
      t.column :output_metadata, json_type, default: {}
      t.text :error_message
      t.column :events, json_type, default: []
      t.string :instructions_digest, index: true
      t.integer :input_tokens, default: 0
      t.integer :output_tokens, default: 0
      t.integer :duration_ms
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
      t.index :status
    end
  end

  private

  # jsonb where the adapter has it, json where it doesn't — same treatment
  # migration 004 gives the engine's tables. solid_agent's own generator
  # writes jsonb, which is right for the PostgreSQL apps it targets; the
  # dummy app runs on SQLite.
  def json_type
    @json_type ||= connection.adapter_name.to_s.downcase.include?("postgres") ? :jsonb : :json
  end
end
