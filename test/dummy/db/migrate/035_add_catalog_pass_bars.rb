# frozen_string_literal: true

class AddCatalogPassBars < ActiveRecord::Migration[7.2]
  def up
    type = connection.adapter_name.to_s.downcase.include?("postgres") ? :jsonb : :json
    catalog_tables.each do |table|
      next unless table_exists?(table)
      next if column_exists?(table, :pass)

      add_column table, :pass, type
    end
  end

  def down
    catalog_tables.each do |table|
      next unless table_exists?(table)
      next unless column_exists?(table, :pass)

      remove_column table, :pass
    end
  end

  private

  def catalog_tables
    %w[scenario_products scenario_sets].map { |table| "#{ActionAgent.table_name_prefix}#{table}" }
  end
end
