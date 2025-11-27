# frozen_string_literal: true
class CreateApplicationAgents < ActiveRecord::Migration[7.0]
  def change
    create_table :application_agents do |t|
      t.string :name, null: false
      t.json  :config, null: false, default: {}
      t.timestamps
    end
  end
end
