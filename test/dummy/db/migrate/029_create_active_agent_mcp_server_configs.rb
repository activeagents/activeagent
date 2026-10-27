# frozen_string_literal: true

# MCP servers a dashboard user adds on the MCP Services page
# (ActionAgent::MCPServerConfig): a remote server's URL, its request headers
# (encrypted at rest, in secret_headers), and what the last connection test
# found. Each row belongs to an account or a user, as provider keys do.
#
# Table names follow ActionAgent.table_name_prefix, and JSON columns are
# jsonb on PostgreSQL and json elsewhere, the same way as
# create_active_agent_dashboard_tables.
class CreateActiveAgentMcpServerConfigs < ActiveRecord::Migration[7.2]
  def change
    prefix = ActionAgent.table_name_prefix

    create_table "#{prefix}mcp_server_configs" do |t|
      t.string :name, null: false
      t.text :description
      t.string :url, null: false, limit: 2048
      # A JSON object of header name => value, encrypted.
      t.text :secret_headers
      t.boolean :enabled, null: false, default: true
      t.datetime :last_tested_at
      # "ok" or "failed", and the error of a failed test.
      t.string :last_test_status
      t.text :last_test_error
      # The tool names the last successful test listed.
      t.column :tool_names, json_type, **json_default([])
      t.bigint :account_id
      t.bigint :user_id
      t.timestamps
      t.index :account_id, name: "index_#{prefix}mcp_server_configs_on_account"
      t.index :user_id, name: "index_#{prefix}mcp_server_configs_on_user"
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
