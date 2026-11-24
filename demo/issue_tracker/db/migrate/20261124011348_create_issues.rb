class CreateIssues < ActiveRecord::Migration[8.1]
  def change
    create_table :issues do |t|
      t.string :title, null: false
      t.text :body
      t.string :status, null: false, default: "open"
      t.string :priority, null: false, default: "medium"
      t.string :component
      t.references :reporter, null: false, foreign_key: { to_table: :users }
      t.references :assignee, foreign_key: { to_table: :users }
      t.references :duplicate_of, foreign_key: { to_table: :issues }
      t.datetime :closed_at

      t.timestamps
    end
    add_index :issues, :status
    add_index :issues, :priority
    add_index :issues, :component
  end
end
