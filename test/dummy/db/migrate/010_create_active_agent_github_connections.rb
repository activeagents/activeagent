# frozen_string_literal: true

# GitHub connections: an owner's OAuth grant (Settings -> Integrations), the
# repositories they made available to the workspace, and the checkout a
# sandbox session boots its app runtime from. Emitted alongside the dashboard
# tables on a fresh install, and on its own for an install that predates it.
#
# Table names follow ActionAgent.table_name_prefix, and JSON columns are
# jsonb on PostgreSQL and json elsewhere, the same way as
# create_active_agent_dashboard_tables.
class CreateActiveAgentGithubConnections < ActiveRecord::Migration[7.2]
  def change
    prefix = ActionAgent.table_name_prefix

    create_table "#{prefix}github_connections" do |t|
      # The OAuth access token, encrypted at rest (text: ciphertext is longer
      # than the token).
      t.text :access_token, null: false
      t.bigint :github_user_id, null: false
      t.string :login, null: false
      t.string :avatar_url
      t.string :scopes
      # The repositories the owner made available, as GitHub described them
      # when they were chosen: full_name, id, private, default_branch.
      t.column :repositories, json_type, **json_default([])
      t.bigint :user_id
      t.bigint :account_id
      t.timestamps
      t.index :account_id
      t.index :user_id
    end

    # A sandbox booted from a checkout of one of those repositories, and the
    # app runtime's MCP endpoint (and the bearer token it expects, encrypted)
    # once the backend reports them.
    change_table "#{prefix}sandbox_sessions" do |t|
      t.string :repository
      t.string :repository_ref
      t.string :runtime_mcp_url
      t.text :runtime_mcp_token
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
