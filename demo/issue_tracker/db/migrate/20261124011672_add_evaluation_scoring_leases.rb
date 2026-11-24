# frozen_string_literal: true

class AddEvaluationScoringLeases < ActiveRecord::Migration[8.1]
  def change
    add_column "#{ActionAgent.table_name_prefix}evaluation_scenario_results", :scoring_token, :string
    add_column "#{ActionAgent.table_name_prefix}evaluation_scenario_results", :scoring_expires_at, :datetime
  end
end
