# frozen_string_literal: true

class AddCodeSessionRunner < ActiveRecord::Migration[7.2]
  def change
    table = "#{ActionAgent.table_name_prefix}code_sessions"
    add_column table, :runner, :string, null: false, default: "claude_code" unless column_exists?(table, :runner)
    add_column table, :runner_session_id, :string unless column_exists?(table, :runner_session_id)
  end
end
