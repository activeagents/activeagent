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

ActiveRecord::Schema[8.1].define(version: 2026_11_24_011676) do
  create_table "active_agent_agent_contexts", force: :cascade do |t|
    t.string "agent_name", null: false
    t.string "action_name", null: false
    t.string "contextable_type"
    t.bigint "contextable_id"
    t.text "instructions"
    t.json "options"
    t.string "trace_id"
    t.integer "total_input_tokens", default: 0
    t.integer "total_output_tokens", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["contextable_type", "contextable_id"], name: "idx_on_contextable_type_contextable_id_572beb2580"
    t.index ["trace_id"], name: "index_active_agent_agent_contexts_on_trace_id"
  end

  create_table "active_agent_agent_generations", force: :cascade do |t|
    t.bigint "agent_context_id", null: false
    t.text "content"
    t.string "model"
    t.string "provider"
    t.string "finish_reason"
    t.integer "input_tokens", default: 0
    t.integer "output_tokens", default: 0
    t.integer "cached_tokens", default: 0
    t.integer "reasoning_tokens", default: 0
    t.float "duration_seconds"
    t.json "tool_calls"
    t.json "raw_response"
    t.json "provenance"
    t.string "trace_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_context_id"], name: "index_active_agent_agent_generations_on_agent_context_id"
    t.index ["trace_id"], name: "index_active_agent_agent_generations_on_trace_id"
  end

  create_table "active_agent_agent_memories", force: :cascade do |t|
    t.string "memorable_type"
    t.bigint "memorable_id"
    t.string "scope", default: "default", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["memorable_type", "memorable_id", "scope"], name: "index_active_agent_memories_on_memorable_and_scope", unique: true
  end

  create_table "active_agent_agent_memory_entries", force: :cascade do |t|
    t.bigint "agent_memory_id", null: false
    t.text "content", null: false
    t.string "source_agent"
    t.string "category"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_memory_id"], name: "index_active_agent_agent_memory_entries_on_agent_memory_id"
  end

  create_table "active_agent_agent_messages", force: :cascade do |t|
    t.bigint "agent_context_id", null: false
    t.string "role", null: false
    t.text "content"
    t.string "content_checksum"
    t.string "tool_call_id"
    t.string "tool_name"
    t.json "tool_arguments"
    t.json "tool_result"
    t.json "attachments"
    t.json "metadata"
    t.json "provenance"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_context_id"], name: "index_active_agent_agent_messages_on_agent_context_id"
  end

  create_table "active_agent_agent_runs", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.string "trace_id"
    t.string "action_name"
    t.integer "status", default: 0, null: false
    t.text "input_prompt"
    t.json "input_params"
    t.text "output"
    t.json "output_metadata"
    t.json "logs"
    t.text "error_message"
    t.text "error_backtrace"
    t.integer "input_tokens"
    t.integer "output_tokens"
    t.integer "total_tokens"
    t.integer "duration_ms"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.bigint "agent_version_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id"], name: "index_active_agent_agent_runs_on_agent_id"
    t.index ["agent_version_id"], name: "index_active_agent_agent_runs_on_agent_version_id"
    t.index ["created_at"], name: "index_active_agent_agent_runs_on_created_at"
    t.index ["trace_id"], name: "index_active_agent_agent_runs_on_trace_id"
  end

  create_table "active_agent_agent_templates", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.text "description"
    t.string "category"
    t.string "icon"
    t.string "provider", default: "openai"
    t.string "model", default: "gpt-4o-mini"
    t.text "instructions"
    t.string "preset_type"
    t.json "appearance"
    t.json "instruction_sets"
    t.json "tools"
    t.json "mcp_servers"
    t.json "model_config"
    t.boolean "featured", default: false
    t.boolean "free_tier", default: false
    t.boolean "public", default: true
    t.integer "usage_count", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_active_agent_agent_templates_on_slug", unique: true
  end

  create_table "active_agent_agent_versions", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.integer "version_number", default: 1, null: false
    t.json "configuration_snapshot"
    t.string "change_summary"
    t.string "created_by"
    t.string "release_digest"
    t.string "revision"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "release_digest"], name: "idx_on_agent_id_release_digest_84a8b4fee1"
    t.index ["agent_id", "version_number"], name: "idx_on_agent_id_version_number_3d7d356d2e", unique: true
  end

  create_table "active_agent_agents", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.text "description"
    t.string "provider", default: "openai"
    t.string "model", default: "gpt-4o-mini"
    t.text "instructions"
    t.string "preset_type"
    t.string "agent_class_name"
    t.string "action_name"
    t.integer "status", default: 0, null: false
    t.json "appearance"
    t.json "instruction_sets"
    t.json "tools"
    t.json "mcp_servers"
    t.json "model_config"
    t.json "response_format"
    t.json "action_prompts"
    t.string "service_name"
    t.string "source"
    t.datetime "first_observed_at"
    t.datetime "last_observed_at"
    t.string "release_digest"
    t.bigint "user_id"
    t.bigint "account_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.json "approval_required_tools"
    t.index ["account_id"], name: "index_active_agent_agents_on_account_id"
    t.index ["status"], name: "index_active_agent_agents_on_status"
    t.index ["user_id", "slug"], name: "index_active_agent_agents_on_user_id_and_slug", unique: true
    t.index ["user_id"], name: "index_active_agent_agents_on_user_id"
  end

  create_table "active_agent_api_keys", force: :cascade do |t|
    t.string "name", null: false
    t.string "token", null: false
    t.string "token_prefix", null: false
    t.datetime "last_used_at"
    t.bigint "user_id"
    t.bigint "account_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["token"], name: "index_active_agent_api_keys_on_token", unique: true
  end

  create_table "active_agent_catalog_scenarios", force: :cascade do |t|
    t.bigint "scenario_set_id", null: false
    t.string "key", null: false
    t.text "prompt", null: false
    t.text "notes"
    t.json "expectations"
    t.json "tags"
    t.json "params"
    t.boolean "production_only", default: false, null: false
    t.boolean "enabled", default: true, null: false
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.json "metadata"
    t.index ["scenario_set_id", "key"], name: "idx_on_scenario_set_id_key_a39d203ecf", unique: true
  end

  create_table "active_agent_code_sessions", force: :cascade do |t|
    t.bigint "sandbox_session_id", null: false
    t.text "prompt", null: false
    t.integer "status", default: 0, null: false
    t.json "events"
    t.integer "dropped_events_count", default: 0, null: false
    t.text "result"
    t.text "diff"
    t.text "error_message"
    t.string "model"
    t.string "claude_session_id"
    t.integer "num_turns"
    t.integer "duration_ms"
    t.decimal "total_cost_usd", precision: 12, scale: 6
    t.integer "input_tokens"
    t.integer "output_tokens"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.bigint "user_id"
    t.bigint "account_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "runner", default: "claude_code", null: false
    t.string "runner_session_id"
    t.bigint "evaluation_run_id"
    t.bigint "verification_run_id"
    t.bigint "previous_code_session_id"
    t.json "fix_item"
    t.string "credential_mode"
    t.text "verification_error"
    t.bigint "conversation_root_id"
    t.integer "turn_index", default: 0, null: false
    t.string "origin"
    t.text "context_note"
    t.string "resume_session_id"
    t.index ["account_id"], name: "index_active_agent_code_sessions_on_account_id"
    t.index ["conversation_root_id"], name: "index_active_agent_code_sessions_on_conversation_root_id"
    t.index ["evaluation_run_id"], name: "index_active_agent_code_sessions_on_evaluation_run_id"
    t.index ["sandbox_session_id"], name: "index_active_agent_code_sessions_on_sandbox_session_id"
    t.index ["user_id"], name: "index_active_agent_code_sessions_on_user_id"
    t.index ["verification_run_id"], name: "index_active_agent_code_sessions_on_verification_run_id"
  end

  create_table "active_agent_draft_pull_requests", force: :cascade do |t|
    t.bigint "sandbox_session_id", null: false
    t.string "repository", null: false
    t.string "base_branch"
    t.string "branch", null: false
    t.string "base_commit", null: false
    t.string "head_commit"
    t.string "title", null: false
    t.text "body"
    t.text "commit_message"
    t.json "files"
    t.string "operation", default: "create", null: false
    t.string "status", default: "queued", null: false
    t.string "error_code"
    t.text "error_message"
    t.string "credential_kind"
    t.integer "number"
    t.string "url"
    t.string "compare_url"
    t.string "state"
    t.boolean "draft"
    t.datetime "last_checked_at"
    t.bigint "user_id"
    t.bigint "account_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_active_agent_draft_pull_requests_on_account"
    t.index ["sandbox_session_id"], name: "index_active_agent_draft_pull_requests_on_sandbox_session"
    t.index ["user_id"], name: "index_active_agent_draft_pull_requests_on_user"
  end

  create_table "active_agent_evaluation_runs", force: :cascade do |t|
    t.bigint "evaluation_id", null: false
    t.integer "status", default: 0, null: false
    t.json "scores"
    t.integer "samples_evaluated", default: 0
    t.integer "samples_passed", default: 0
    t.text "error_message"
    t.datetime "completed_at"
    t.bigint "agent_version_id"
    t.string "external_tenant"
    t.string "external_run_id"
    t.string "external_report_digest"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.json "selection"
    t.index ["agent_version_id"], name: "index_active_agent_evaluation_runs_on_agent_version_id"
    t.index ["evaluation_id"], name: "index_active_agent_evaluation_runs_on_evaluation_id"
    t.index ["external_tenant", "external_run_id"], name: "index_active_agent_evaluation_runs_on_external_identity", unique: true
  end

  create_table "active_agent_evaluation_scenario_results", force: :cascade do |t|
    t.bigint "evaluation_run_id", null: false
    t.bigint "evaluation_scenario_id", null: false
    t.bigint "agent_run_id"
    t.string "model", null: false
    t.string "provider"
    t.integer "status", default: 0, null: false
    t.float "score"
    t.json "scores"
    t.text "output"
    t.json "tool_calls"
    t.integer "duration_ms"
    t.integer "input_tokens"
    t.integer "output_tokens"
    t.decimal "cost", precision: 12, scale: 6
    t.string "fault"
    t.text "recommendation"
    t.json "diagnosis"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "scoring_token"
    t.datetime "scoring_expires_at"
    t.index ["evaluation_run_id", "model"], name: "index_active_agent_evaluation_scenario_results_on_run_and_model"
    t.index ["evaluation_run_id"], name: "index_active_agent_evaluation_scenario_results_on_run"
    t.index ["evaluation_scenario_id"], name: "index_active_agent_evaluation_scenario_results_on_scenario"
  end

  create_table "active_agent_evaluation_scenarios", force: :cascade do |t|
    t.bigint "evaluation_id", null: false
    t.string "key", null: false
    t.string "group"
    t.text "prompt", null: false
    t.text "notes"
    t.json "expectations"
    t.integer "position", default: 0, null: false
    t.boolean "enabled", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["evaluation_id", "group"], name: "index_active_agent_evaluation_scenarios_on_evaluation_and_group"
    t.index ["evaluation_id", "key"], name: "index_active_agent_evaluation_scenarios_on_evaluation_and_key", unique: true
  end

  create_table "active_agent_evaluations", force: :cascade do |t|
    t.bigint "agent_id", null: false
    t.string "name", null: false
    t.string "judge_kind", default: "rules", null: false
    t.string "judge_model"
    t.integer "sample_size", default: 20, null: false
    t.json "criteria"
    t.json "config"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "name"], name: "index_active_agent_evaluations_on_agent_id_and_name", unique: true
  end

  create_table "active_agent_explorations", force: :cascade do |t|
    t.bigint "project_id"
    t.bigint "evaluation_id"
    t.bigint "agent_run_id"
    t.bigint "sandbox_session_id"
    t.bigint "session_recording_id"
    t.string "source", default: "external", null: false
    t.string "status", default: "pending", null: false
    t.string "start_url"
    t.string "stop_reason"
    t.text "error_message"
    t.datetime "started_at"
    t.datetime "finished_at"
    t.json "budget"
    t.json "usage"
    t.json "candidates"
    t.bigint "account_id"
    t.bigint "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_active_agent_explorations_on_account_id"
    t.index ["evaluation_id"], name: "index_active_agent_explorations_on_evaluation_id"
    t.index ["project_id"], name: "index_active_agent_explorations_on_project_id"
    t.index ["user_id"], name: "index_active_agent_explorations_on_user_id"
  end

  create_table "active_agent_github_connections", force: :cascade do |t|
    t.text "access_token", null: false
    t.bigint "github_user_id", null: false
    t.string "login", null: false
    t.string "avatar_url"
    t.string "scopes"
    t.json "repositories"
    t.bigint "user_id"
    t.bigint "account_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_active_agent_github_connections_on_account_id"
    t.index ["user_id"], name: "index_active_agent_github_connections_on_user_id"
  end

  create_table "active_agent_github_installations", force: :cascade do |t|
    t.bigint "installation_id", null: false
    t.bigint "github_account_id", null: false
    t.string "github_account_login", null: false
    t.string "github_account_type", null: false
    t.string "repository_selection"
    t.json "permissions"
    t.json "repositories"
    t.datetime "suspended_at"
    t.datetime "removed_at"
    t.bigint "user_id"
    t.bigint "account_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_active_agent_github_installations_on_account"
    t.index ["installation_id"], name: "index_active_agent_github_installations_on_installation", unique: true
    t.index ["user_id"], name: "index_active_agent_github_installations_on_user"
  end

  create_table "active_agent_github_webhook_deliveries", force: :cascade do |t|
    t.string "delivery_id", limit: 64, null: false
    t.string "event", limit: 64, null: false
    t.string "event_action", limit: 64
    t.bigint "installation_id"
    t.datetime "created_at", null: false
    t.index ["created_at"], name: "index_active_agent_webhook_deliveries_on_created_at"
    t.index ["delivery_id"], name: "index_active_agent_webhook_deliveries_on_delivery", unique: true
  end

  create_table "active_agent_input_requests", force: :cascade do |t|
    t.string "subject_type", null: false
    t.bigint "subject_id", null: false
    t.string "pause_key", null: false
    t.string "kind", null: false
    t.text "prompt", null: false
    t.json "options"
    t.json "answer_schema"
    t.string "tool_call_id"
    t.string "tool_name"
    t.json "arguments"
    t.integer "status", default: 0, null: false
    t.text "answer"
    t.text "checkpoint"
    t.bigint "requested_by_id"
    t.bigint "answered_by_id"
    t.datetime "answered_at"
    t.datetime "expires_at"
    t.bigint "user_id"
    t.bigint "account_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_active_agent_input_requests_on_account_id"
    t.index ["pause_key"], name: "index_active_agent_input_requests_on_pause_key"
    t.index ["status", "expires_at"], name: "index_active_agent_input_requests_on_status_and_expires_at"
    t.index ["subject_type", "subject_id"], name: "idx_on_subject_type_subject_id_d502213c76"
    t.index ["user_id"], name: "index_active_agent_input_requests_on_user_id"
  end

  create_table "active_agent_interaction_feedbacks", force: :cascade do |t|
    t.integer "telemetry_trace_id", null: false
    t.string "feedback_id", limit: 128, null: false
    t.string "rating", limit: 16, null: false
    t.string "span_id", limit: 128
    t.string "user_reference", limit: 255
    t.text "comment"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["telemetry_trace_id", "feedback_id"], name: "index_feedback_on_trace_and_feedback_id", unique: true
    t.index ["telemetry_trace_id"], name: "index_active_agent_interaction_feedbacks_on_telemetry_trace_id"
  end

  create_table "active_agent_mcp_server_configs", force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.string "url", limit: 2048, null: false
    t.text "secret_headers"
    t.boolean "enabled", default: true, null: false
    t.datetime "last_tested_at"
    t.string "last_test_status"
    t.text "last_test_error"
    t.json "tool_names"
    t.bigint "account_id"
    t.bigint "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_active_agent_mcp_server_configs_on_account"
    t.index ["user_id"], name: "index_active_agent_mcp_server_configs_on_user"
  end

  create_table "active_agent_project_secrets", force: :cascade do |t|
    t.bigint "project_id", null: false
    t.string "name", null: false
    t.text "value"
    t.string "source", default: "entered", null: false
    t.string "provider"
    t.datetime "consented_at"
    t.bigint "set_by_id"
    t.bigint "account_id"
    t.bigint "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "kind", default: "env", null: false
    t.index ["account_id"], name: "index_active_agent_project_secrets_on_account_id"
    t.index ["project_id", "name"], name: "index_active_agent_project_secrets_on_project_id_and_name", unique: true
    t.index ["user_id"], name: "index_active_agent_project_secrets_on_user_id"
  end

  create_table "active_agent_projects", force: :cascade do |t|
    t.string "name", null: false
    t.string "repository", null: false
    t.string "default_ref"
    t.string "start_url", default: "/", null: false
    t.string "status", default: "draft", null: false
    t.string "install_state", default: "detected", null: false
    t.bigint "current_sandbox_session_id"
    t.bigint "target_agent_id"
    t.bigint "evaluation_id"
    t.json "settings"
    t.bigint "account_id"
    t.bigint "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_active_agent_projects_on_account_id"
    t.index ["current_sandbox_session_id"], name: "index_active_agent_projects_on_current_sandbox_session_id"
    t.index ["target_agent_id"], name: "index_active_agent_projects_on_target_agent_id"
    t.index ["user_id"], name: "index_active_agent_projects_on_user_id"
  end

  create_table "active_agent_provider_keys", force: :cascade do |t|
    t.string "provider", null: false
    t.string "credential", null: false
    t.string "api_key"
    t.bigint "user_id"
    t.bigint "account_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "scope_key", default: "organization", null: false
    t.bigint "set_by_id"
    t.index ["account_id", "provider"], name: "index_active_agent_provider_keys_on_account_id_and_provider"
    t.index ["account_id", "scope_key", "provider"], name: "index_active_agent_provider_keys_on_scope", unique: true
    t.index ["user_id", "provider"], name: "index_active_agent_provider_keys_on_user_id_and_provider"
  end

  create_table "active_agent_recording_actions", force: :cascade do |t|
    t.bigint "session_recording_id", null: false
    t.integer "sequence", null: false
    t.string "action_type", null: false
    t.string "selector"
    t.text "value"
    t.integer "timestamp_ms", null: false
    t.string "screenshot_key"
    t.string "dom_snapshot_key"
    t.json "metadata"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["session_recording_id", "sequence"], name: "index_active_agent_recording_actions_on_recording_and_sequence", unique: true
  end

  create_table "active_agent_recording_events", force: :cascade do |t|
    t.bigint "session_recording_id", null: false
    t.string "kind", null: false
    t.datetime "occurred_from", null: false
    t.datetime "occurred_to", null: false
    t.integer "batch_index", default: 0, null: false
    t.bigint "clock_offset_ms", default: 0, null: false
    t.integer "event_count", default: 0, null: false
    t.integer "byte_size", default: 0, null: false
    t.binary "payload", limit: 16777216
    t.bigint "user_id"
    t.bigint "account_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_active_agent_recording_events_on_account_id"
    t.index ["session_recording_id", "occurred_from", "batch_index"], name: "idx_on_session_recording_id_occurred_from_batch_ind_123f75800d"
    t.index ["user_id"], name: "index_active_agent_recording_events_on_user_id"
  end

  create_table "active_agent_recording_snapshots", force: :cascade do |t|
    t.bigint "session_recording_id", null: false
    t.bigint "recording_action_id"
    t.string "snapshot_type", null: false
    t.string "storage_key", null: false
    t.integer "width"
    t.integer "height"
    t.integer "file_size_bytes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["recording_action_id"], name: "index_active_agent_recording_snapshots_on_recording_action_id"
    t.index ["session_recording_id"], name: "index_active_agent_recording_snapshots_on_session_recording_id"
  end

  create_table "active_agent_sandbox_runs", force: :cascade do |t|
    t.bigint "sandbox_session_id"
    t.text "task", null: false
    t.integer "status", default: 0, null: false
    t.text "result"
    t.text "error"
    t.json "screenshots"
    t.integer "tokens_used", default: 0
    t.integer "duration_ms"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["sandbox_session_id"], name: "index_active_agent_sandbox_runs_on_sandbox_session_id"
  end

  create_table "active_agent_sandbox_sessions", force: :cascade do |t|
    t.string "session_id", null: false
    t.bigint "agent_template_id"
    t.integer "status", default: 0
    t.string "sandbox_type", default: "playwright_mcp"
    t.string "cloud_run_job_id"
    t.string "cloud_run_url"
    t.json "runs"
    t.json "mcp_servers"
    t.integer "runs_count", default: 0
    t.integer "max_runs", default: 10
    t.integer "timeout_seconds", default: 300
    t.integer "total_duration_ms", default: 0
    t.integer "total_tokens", default: 0
    t.text "error_message"
    t.datetime "expires_at"
    t.datetime "last_activity_at"
    t.bigint "user_id"
    t.bigint "account_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "repository"
    t.string "repository_ref"
    t.string "runtime_mcp_url"
    t.text "runtime_mcp_token"
    t.string "browser_mode"
    t.string "browser_status"
    t.string "browser_mcp_url"
    t.string "browser_live_url"
    t.text "browser_token"
    t.datetime "browser_started_at"
    t.bigint "project_id"
    t.bigint "github_installation_id"
    t.bigint "claude_login_user_id"
    t.index ["github_installation_id"], name: "index_active_agent_sandbox_sessions_on_github_installation"
    t.index ["project_id"], name: "index_active_agent_sandbox_sessions_on_project_id"
    t.index ["session_id"], name: "index_active_agent_sandbox_sessions_on_session_id", unique: true
    t.index ["user_id"], name: "index_active_agent_sandbox_sessions_on_user_id"
  end

  create_table "active_agent_scenario_catalogs", force: :cascade do |t|
    t.string "key", null: false
    t.string "name", null: false
    t.text "description"
    t.string "source_kind", default: "upload", null: false
    t.string "source_path"
    t.string "digest"
    t.text "document"
    t.datetime "synced_at"
    t.string "synced_digest"
    t.json "metadata"
    t.bigint "account_id"
    t.bigint "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_active_agent_scenario_catalogs_on_account_id"
    t.index ["key"], name: "index_active_agent_scenario_catalogs_on_key"
    t.index ["user_id"], name: "index_active_agent_scenario_catalogs_on_user_id"
  end

  create_table "active_agent_scenario_products", force: :cascade do |t|
    t.bigint "scenario_catalog_id", null: false
    t.string "key", null: false
    t.string "name", null: false
    t.text "description"
    t.bigint "agent_id"
    t.bigint "project_id"
    t.string "agent_name"
    t.integer "position"
    t.json "metadata"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.json "criteria"
    t.json "pass"
    t.index ["agent_id"], name: "index_active_agent_scenario_products_on_agent_id"
    t.index ["project_id"], name: "index_active_agent_scenario_products_on_project_id"
    t.index ["scenario_catalog_id", "key"], name: "idx_on_scenario_catalog_id_key_2062a9535b", unique: true
  end

  create_table "active_agent_scenario_sets", force: :cascade do |t|
    t.bigint "scenario_product_id", null: false
    t.string "key", null: false
    t.string "name", null: false
    t.text "description"
    t.json "judge"
    t.json "criteria"
    t.json "metadata"
    t.bigint "evaluation_id"
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.json "pass"
    t.index ["evaluation_id"], name: "index_active_agent_scenario_sets_on_evaluation_id"
    t.index ["scenario_product_id", "key"], name: "idx_on_scenario_product_id_key_dec134b9c6", unique: true
  end

  create_table "active_agent_session_recordings", force: :cascade do |t|
    t.string "name"
    t.bigint "agent_run_id"
    t.bigint "sandbox_session_id"
    t.integer "status", default: 0, null: false
    t.integer "action_count", default: 0
    t.integer "duration_ms"
    t.json "metadata"
    t.bigint "user_id"
    t.bigint "account_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "agent_context_id"
    t.string "source"
    t.string "ingest_token_digest"
    t.datetime "ingest_token_expires_at"
    t.integer "event_count", default: 0, null: false
    t.bigint "event_bytes", default: 0, null: false
    t.integer "dropped_event_count", default: 0, null: false
    t.index ["account_id"], name: "index_active_agent_session_recordings_on_account_id"
    t.index ["agent_context_id"], name: "index_active_agent_session_recordings_on_agent_context_id"
    t.index ["agent_run_id"], name: "index_active_agent_session_recordings_on_agent_run_id"
    t.index ["ingest_token_digest"], name: "index_active_agent_session_recordings_on_ingest_token_digest", unique: true
    t.index ["sandbox_session_id"], name: "index_active_agent_session_recordings_on_sandbox_session_id"
    t.index ["user_id"], name: "index_active_agent_session_recordings_on_user_id"
  end

  create_table "active_agent_telemetry_traces", force: :cascade do |t|
    t.string "trace_id", null: false
    t.string "service_name"
    t.string "environment"
    t.datetime "timestamp"
    t.json "spans"
    t.json "resource_attributes"
    t.json "sdk_info"
    t.decimal "total_duration_ms", precision: 12, scale: 3
    t.integer "total_input_tokens", default: 0
    t.integer "total_output_tokens", default: 0
    t.integer "total_thinking_tokens", default: 0
    t.string "status"
    t.string "agent_class"
    t.string "agent_action"
    t.bigint "agent_id"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "agent_version_id"
    t.index ["agent_class", "agent_action"], name: "idx_on_agent_class_agent_action_c68bed0fe3"
    t.index ["agent_class"], name: "index_active_agent_telemetry_traces_on_agent_class"
    t.index ["agent_id"], name: "index_active_agent_telemetry_traces_on_agent_id"
    t.index ["agent_version_id"], name: "index_active_agent_telemetry_traces_on_agent_version_id"
    t.index ["created_at"], name: "index_active_agent_telemetry_traces_on_created_at"
    t.index ["service_name", "environment"], name: "idx_on_service_name_environment_aa52e7b090"
    t.index ["status"], name: "index_active_agent_telemetry_traces_on_status"
    t.index ["timestamp"], name: "index_active_agent_telemetry_traces_on_timestamp"
    t.index ["trace_id"], name: "index_active_agent_telemetry_traces_on_trace_id", unique: true
  end

  create_table "comments", force: :cascade do |t|
    t.integer "issue_id", null: false
    t.integer "author_id", null: false
    t.text "body", null: false
    t.boolean "via_agent", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_comments_on_author_id"
    t.index ["issue_id"], name: "index_comments_on_issue_id"
  end

  create_table "issues", force: :cascade do |t|
    t.string "title", null: false
    t.text "body"
    t.string "status", default: "open", null: false
    t.string "priority", default: "medium", null: false
    t.string "component"
    t.integer "reporter_id", null: false
    t.integer "assignee_id"
    t.integer "duplicate_of_id"
    t.datetime "closed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["assignee_id"], name: "index_issues_on_assignee_id"
    t.index ["component"], name: "index_issues_on_component"
    t.index ["duplicate_of_id"], name: "index_issues_on_duplicate_of_id"
    t.index ["priority"], name: "index_issues_on_priority"
    t.index ["reporter_id"], name: "index_issues_on_reporter_id"
    t.index ["status"], name: "index_issues_on_status"
  end

  create_table "users", force: :cascade do |t|
    t.string "name", null: false
    t.string "handle", null: false
    t.string "team", default: "support", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["handle"], name: "index_users_on_handle", unique: true
  end

  add_foreign_key "active_agent_interaction_feedbacks", "active_agent_telemetry_traces", column: "telemetry_trace_id", on_delete: :cascade
  add_foreign_key "comments", "issues"
  add_foreign_key "comments", "users", column: "author_id"
  add_foreign_key "issues", "issues", column: "duplicate_of_id"
  add_foreign_key "issues", "users", column: "assignee_id"
  add_foreign_key "issues", "users", column: "reporter_id"
end
