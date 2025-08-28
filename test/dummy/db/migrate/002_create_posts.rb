# frozen_string_literal: true

class CreatePosts < ActiveRecord::Migration[7.0]
  def change
    create_table :posts do |t|
      t.string :title, null: false
      t.text :content
      t.references :user, foreign_key: true
      t.boolean :published, default: false
      t.datetime :published_at

      t.timestamps
    end

    add_index :posts, :published
  end
end
