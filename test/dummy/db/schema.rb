# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 3) do
  create_table "posts", force: :cascade do |t|
    t.string "title", null: false
    t.text "content"
    t.integer "user_id"
    t.boolean "published", default: false
    t.datetime "published_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index [ "published" ], name: "index_posts_on_published"
    t.index [ "user_id" ], name: "index_posts_on_user_id"
  end

  create_table "profiles", force: :cascade do |t|
    t.integer "user_id"
    t.text "bio"
    t.string "location"
    t.string "website"
    t.json "social_links"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index [ "user_id" ], name: "index_profiles_on_user_id", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.string "name", null: false
    t.string "email", null: false
    t.integer "age"
    t.string "role", default: "user"
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index [ "email" ], name: "index_users_on_email", unique: true
  end

  add_foreign_key "posts", "users"
  add_foreign_key "profiles", "users"
end
