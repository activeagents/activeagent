# frozen_string_literal: true

class AddAgentRunExecutionLeases < ActiveRecord::Migration[7.2]
  def change
    add_column "#{ActionAgent.table_name_prefix}agent_runs", :execution_token, :string
    add_column "#{ActionAgent.table_name_prefix}agent_runs", :execution_expires_at, :datetime
    add_index "#{ActionAgent.table_name_prefix}agent_runs", [ :status, :execution_expires_at ],
      name: "index_#{ActionAgent.table_name_prefix}agent_runs_on_status_and_lease"
  end
end
