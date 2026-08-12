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

ActiveRecord::Schema[8.1].define(version: 4) do
  create_table "active_agent_agent_contexts", force: :cascade do |t|
    t.string "action_name", null: false
    t.string "agent_name", null: false
    t.bigint "contextable_id"
    t.string "contextable_type"
    t.datetime "created_at", null: false
    t.text "instructions"
    t.json "options", default: {}
    t.integer "total_input_tokens", default: 0
    t.integer "total_output_tokens", default: 0
    t.string "trace_id"
    t.datetime "updated_at", null: false
    t.index ["contextable_type", "contextable_id"], name: "idx_on_contextable_type_contextable_id_572beb2580"
    t.index ["trace_id"], name: "index_active_agent_agent_contexts_on_trace_id"
  end

  create_table "active_agent_agent_generations", force: :cascade do |t|
    t.bigint "agent_context_id", null: false
    t.integer "cached_tokens", default: 0
    t.text "content"
    t.datetime "created_at", null: false
    t.float "duration_seconds"
    t.string "finish_reason"
    t.integer "input_tokens", default: 0
    t.string "model"
    t.integer "output_tokens", default: 0
    t.json "provenance", default: {}
    t.string "provider"
    t.json "raw_response"
    t.integer "reasoning_tokens", default: 0
    t.json "tool_calls", default: []
    t.string "trace_id"
    t.datetime "updated_at", null: false
    t.index ["agent_context_id"], name: "index_active_agent_agent_generations_on_agent_context_id"
    t.index ["trace_id"], name: "index_active_agent_agent_generations_on_trace_id"
  end

  create_table "active_agent_agent_memories", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "memorable_id"
    t.string "memorable_type"
    t.string "scope", default: "default", null: false
    t.datetime "updated_at", null: false
    t.index ["memorable_type", "memorable_id", "scope"], name: "index_active_agent_memories_on_memorable_and_scope", unique: true
  end

  create_table "active_agent_agent_memory_entries", force: :cascade do |t|
    t.bigint "agent_memory_id", null: false
    t.string "category"
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.string "source_agent"
    t.datetime "updated_at", null: false
    t.index ["agent_memory_id"], name: "index_active_agent_agent_memory_entries_on_agent_memory_id"
  end

  create_table "active_agent_agent_messages", force: :cascade do |t|
    t.bigint "agent_context_id", null: false
    t.json "attachments", default: []
    t.text "content"
    t.string "content_checksum"
    t.datetime "created_at", null: false
    t.json "metadata", default: {}
    t.json "provenance", default: {}
    t.string "role", null: false
    t.json "tool_arguments", default: {}
    t.string "tool_call_id"
    t.string "tool_name"
    t.json "tool_result"
    t.datetime "updated_at", null: false
    t.index ["agent_context_id"], name: "index_active_agent_agent_messages_on_agent_context_id"
  end

  create_table "active_agent_agent_runs", force: :cascade do |t|
    t.string "action_name"
    t.bigint "agent_id", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.text "error_backtrace"
    t.text "error_message"
    t.json "input_params", default: {}
    t.text "input_prompt"
    t.integer "input_tokens"
    t.json "logs", default: []
    t.text "output"
    t.json "output_metadata", default: {}
    t.integer "output_tokens"
    t.datetime "started_at"
    t.integer "status", default: 0, null: false
    t.integer "total_tokens"
    t.string "trace_id"
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_active_agent_agent_runs_on_agent_id"
    t.index ["created_at"], name: "index_active_agent_agent_runs_on_created_at"
    t.index ["trace_id"], name: "index_active_agent_agent_runs_on_trace_id"
  end

  create_table "active_agent_agent_templates", force: :cascade do |t|
    t.json "appearance", default: {}
    t.string "category"
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "featured", default: false
    t.boolean "free_tier", default: false
    t.string "icon"
    t.json "instruction_sets", default: []
    t.text "instructions"
    t.json "mcp_servers", default: {}
    t.string "model", default: "gpt-4o-mini"
    t.json "model_config", default: {}
    t.string "name", null: false
    t.string "preset_type"
    t.string "provider", default: "openai"
    t.boolean "public", default: true
    t.string "slug", null: false
    t.json "tools", default: []
    t.datetime "updated_at", null: false
    t.integer "usage_count", default: 0
    t.index ["slug"], name: "index_active_agent_agent_templates_on_slug", unique: true
  end

  create_table "active_agent_agent_versions", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.string "change_summary"
    t.json "configuration_snapshot", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "created_by"
    t.datetime "updated_at", null: false
    t.integer "version_number", default: 1, null: false
    t.index ["agent_id", "version_number"], name: "idx_on_agent_id_version_number_3d7d356d2e", unique: true
  end

  create_table "active_agent_agents", force: :cascade do |t|
    t.bigint "account_id"
    t.string "action_name"
    t.json "action_prompts", default: [], null: false
    t.string "agent_class_name"
    t.json "appearance", default: {}
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "first_observed_at"
    t.json "instruction_sets", default: []
    t.text "instructions"
    t.datetime "last_observed_at"
    t.json "mcp_servers", default: []
    t.string "model", default: "gpt-4o-mini"
    t.json "model_config", default: {}
    t.string "name", null: false
    t.string "preset_type"
    t.string "provider", default: "openai"
    t.json "response_format", default: {}
    t.string "service_name"
    t.string "slug", null: false
    t.string "source"
    t.integer "status", default: 0, null: false
    t.json "tools", default: []
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["account_id"], name: "index_active_agent_agents_on_account_id"
    t.index ["status"], name: "index_active_agent_agents_on_status"
    t.index ["user_id", "slug"], name: "index_active_agent_agents_on_user_id_and_slug", unique: true
    t.index ["user_id"], name: "index_active_agent_agents_on_user_id"
  end

  create_table "active_agent_api_keys", force: :cascade do |t|
    t.bigint "account_id"
    t.datetime "created_at", null: false
    t.datetime "last_used_at"
    t.string "name", null: false
    t.string "token", null: false
    t.string "token_prefix", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["token"], name: "index_active_agent_api_keys_on_token", unique: true
  end

  create_table "active_agent_evaluation_runs", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.bigint "evaluation_id", null: false
    t.integer "samples_evaluated", default: 0
    t.integer "samples_passed", default: 0
    t.json "scores", default: {}
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["evaluation_id"], name: "index_active_agent_evaluation_runs_on_evaluation_id"
  end

  create_table "active_agent_evaluations", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.json "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.json "criteria", default: [], null: false
    t.string "judge_kind", default: "rules", null: false
    t.string "judge_model"
    t.string "name", null: false
    t.integer "sample_size", default: 20, null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "name"], name: "index_active_agent_evaluations_on_agent_id_and_name", unique: true
  end

  create_table "active_agent_provider_keys", force: :cascade do |t|
    t.bigint "account_id"
    t.datetime "created_at", null: false
    t.string "credential", null: false
    t.string "provider", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["account_id", "provider"], name: "index_active_agent_provider_keys_on_account_id_and_provider"
    t.index ["user_id", "provider"], name: "index_active_agent_provider_keys_on_user_id_and_provider"
  end

  create_table "active_agent_recording_actions", force: :cascade do |t|
    t.string "action_type", null: false
    t.datetime "created_at", null: false
    t.string "dom_snapshot_key"
    t.json "metadata", default: {}
    t.string "screenshot_key"
    t.string "selector"
    t.integer "sequence", null: false
    t.bigint "session_recording_id", null: false
    t.integer "timestamp_ms", null: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.index ["session_recording_id", "sequence"], name: "index_active_agent_recording_actions_on_recording_and_sequence", unique: true
  end

  create_table "active_agent_recording_snapshots", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "file_size_bytes"
    t.integer "height"
    t.bigint "recording_action_id"
    t.bigint "session_recording_id", null: false
    t.string "snapshot_type", null: false
    t.string "storage_key", null: false
    t.datetime "updated_at", null: false
    t.integer "width"
    t.index ["recording_action_id"], name: "index_active_agent_recording_snapshots_on_recording_action_id"
    t.index ["session_recording_id"], name: "index_active_agent_recording_snapshots_on_session_recording_id"
  end

  create_table "active_agent_sandbox_runs", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.text "error"
    t.text "result"
    t.bigint "sandbox_session_id"
    t.json "screenshots", default: []
    t.datetime "started_at"
    t.integer "status", default: 0, null: false
    t.text "task", null: false
    t.integer "tokens_used", default: 0
    t.datetime "updated_at", null: false
    t.index ["sandbox_session_id"], name: "index_active_agent_sandbox_runs_on_sandbox_session_id"
  end

  create_table "active_agent_sandbox_sessions", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "agent_template_id"
    t.string "cloud_run_job_id"
    t.string "cloud_run_url"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.datetime "expires_at"
    t.datetime "last_activity_at"
    t.integer "max_runs", default: 10
    t.json "runs", default: []
    t.integer "runs_count", default: 0
    t.string "sandbox_type", default: "playwright_mcp"
    t.string "session_id", null: false
    t.integer "status", default: 0
    t.integer "timeout_seconds", default: 300
    t.integer "total_duration_ms", default: 0
    t.integer "total_tokens", default: 0
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["session_id"], name: "index_active_agent_sandbox_sessions_on_session_id", unique: true
    t.index ["user_id"], name: "index_active_agent_sandbox_sessions_on_user_id"
  end

  create_table "active_agent_session_recordings", force: :cascade do |t|
    t.bigint "account_id"
    t.integer "action_count", default: 0
    t.bigint "agent_run_id"
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.json "metadata", default: {}
    t.string "name"
    t.bigint "sandbox_session_id"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["account_id"], name: "index_active_agent_session_recordings_on_account_id"
    t.index ["agent_run_id"], name: "index_active_agent_session_recordings_on_agent_run_id"
    t.index ["sandbox_session_id"], name: "index_active_agent_session_recordings_on_sandbox_session_id"
    t.index ["user_id"], name: "index_active_agent_session_recordings_on_user_id"
  end

  create_table "posts", force: :cascade do |t|
    t.text "content"
    t.datetime "created_at", null: false
    t.boolean "published", default: false
    t.datetime "published_at"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["published"], name: "index_posts_on_published"
    t.index ["user_id"], name: "index_posts_on_user_id"
  end

  create_table "profiles", force: :cascade do |t|
    t.text "bio"
    t.datetime "created_at", null: false
    t.string "location"
    t.json "social_links"
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.string "website"
    t.index ["user_id"], name: "index_profiles_on_user_id", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.boolean "active", default: true
    t.integer "age"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "name", null: false
    t.string "role", default: "user"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "posts", "users"
  add_foreign_key "profiles", "users"
end
