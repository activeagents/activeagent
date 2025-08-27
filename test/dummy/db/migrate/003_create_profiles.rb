# frozen_string_literal: true

class CreateProfiles < ActiveRecord::Migration[7.0]
  def change
    create_table :profiles do |t|
      t.references :user, foreign_key: true, index: {unique: true}
      t.text :bio
      t.string :location
      t.string :website
      t.json :social_links
      
      t.timestamps
    end
  end
end