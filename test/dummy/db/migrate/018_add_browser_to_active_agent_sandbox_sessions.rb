# frozen_string_literal: true

# Browser sessions: a sandbox can run one browser, driven over MCP by the
# agents run against it. Each sandbox session records the browser's mode and
# status, where its MCP endpoint answers and the bearer token it expects
# (encrypted, like runtime_mcp_token), where a person can watch it, and when
# it started, which is what its minutes are counted from.
#
# Table names follow ActionAgent.table_name_prefix, the same way as
# create_active_agent_dashboard_tables.
class AddBrowserToActiveAgentSandboxSessions < ActiveRecord::Migration[7.2]
  def change
    change_table "#{ActionAgent.table_name_prefix}sandbox_sessions" do |t|
      # "headless" or "headed".
      t.string :browser_mode
      # "starting", "running", "stopped" or "failed"; null before a browser
      # was ever started.
      t.string :browser_status
      t.string :browser_mcp_url
      t.string :browser_live_url
      t.text :browser_token
      t.datetime :browser_started_at
    end
  end
end
