# frozen_string_literal: true

# Explorations: a walk through a project's running app, by the engine's
# explorer agent or by an outside agent, and the candidate scenarios it
# proposed for review. Accepted candidates are merged into the project's
# evaluation; the rest stay here with their verdicts and provenance.
#
# Table names follow ActionAgent.table_name_prefix, and JSON columns are
# jsonb on PostgreSQL and json elsewhere, the same way as
# create_active_agent_dashboard_tables.
class CreateActiveAgentExplorations < ActiveRecord::Migration[7.2]
  def change
    prefix = ActionAgent.table_name_prefix

    create_table "#{prefix}explorations" do |t|
      # At least one is set: a project's explorations merge into the
      # project's evaluation, and one without a project into its own.
      t.bigint :project_id
      t.bigint :evaluation_id
      t.bigint :agent_run_id
      t.bigint :sandbox_session_id
      t.bigint :session_recording_id
      # explorer: the engine's explorer agent; external: candidates an
      # outside agent submitted.
      t.string :source, null: false, default: "external"
      t.string :status, null: false, default: "pending"
      t.string :start_url
      t.string :stop_reason
      t.text :error_message
      t.datetime :started_at
      t.datetime :finished_at
      # { minutes, steps, cost }, the limits and what was used of them.
      t.column :budget, json_type, **json_default({})
      t.column :usage, json_type, **json_default({})
      t.column :candidates, json_type, **json_default([])
      t.bigint :account_id
      t.bigint :user_id
      t.timestamps
      t.index :project_id
      t.index :evaluation_id
      t.index :account_id
      t.index :user_id
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
