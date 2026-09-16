# frozen_string_literal: true

# Agent releases: a version cut from the agent's code carries the digest of
# what the model was given and the deploy it shipped in, and every trace,
# run and evaluation run records the version it ran under. Emitted for an
# install whose dashboard tables predate releases; the create-table
# migration carries the same columns for a fresh install.
#
# Each step is guarded so the migration is safe to re-run against a database
# that already has some of these columns.
class AddAgentReleases < ActiveRecord::Migration[7.2]
  def up
    add_column_unless_exists :active_agent_agents, :release_digest, :string

    add_column_unless_exists :active_agent_agent_versions, :release_digest, :string
    add_column_unless_exists :active_agent_agent_versions, :revision, :string
    add_index_unless_exists :active_agent_agent_versions, [ :agent_id, :release_digest ]

    %i[active_agent_telemetry_traces active_agent_agent_runs active_agent_evaluation_runs].each do |table|
      add_column_unless_exists table, :agent_version_id, :bigint
      add_index_unless_exists table, :agent_version_id
    end
  end

  def down
    remove_column :active_agent_agents, :release_digest if column_exists?(:active_agent_agents, :release_digest)
    remove_column :active_agent_agent_versions, :release_digest if column_exists?(:active_agent_agent_versions, :release_digest)
    remove_column :active_agent_agent_versions, :revision if column_exists?(:active_agent_agent_versions, :revision)

    %i[active_agent_telemetry_traces active_agent_agent_runs active_agent_evaluation_runs].each do |table|
      remove_column table, :agent_version_id if column_exists?(table, :agent_version_id)
    end
  end

  private

  def add_column_unless_exists(table, column, type)
    return unless table_exists?(table)
    return if column_exists?(table, column)

    add_column table, column, type
  end

  def add_index_unless_exists(table, columns)
    return unless table_exists?(table)
    return if index_exists?(table, columns)

    add_index table, columns
  end
end
