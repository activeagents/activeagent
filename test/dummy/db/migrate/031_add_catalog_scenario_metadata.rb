# frozen_string_literal: true

class AddCatalogScenarioMetadata < ActiveRecord::Migration[7.2]
  def up
    return unless table_exists?(scenarios_table)
    return if column_exists?(scenarios_table, :metadata)

    type = connection.adapter_name.to_s.downcase.include?("postgres") ? :jsonb : :json
    add_column scenarios_table, :metadata, type
  end

  def down
    return unless table_exists?(scenarios_table)
    return unless column_exists?(scenarios_table, :metadata)

    remove_column scenarios_table, :metadata
  end

  private

  def scenarios_table
    "#{ActionAgent.table_name_prefix}catalog_scenarios"
  end
end
