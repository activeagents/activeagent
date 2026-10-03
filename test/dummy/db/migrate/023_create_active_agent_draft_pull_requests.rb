# frozen_string_literal: true

# Draft pull requests opened from a checkout sandbox's changes (Settings ->
# Integrations -> Open draft PR), and the state GitHub last reported for each.
#
# Table names follow ActionAgent.table_name_prefix, and JSON columns are
# jsonb on PostgreSQL and json elsewhere, the same way as
# create_active_agent_dashboard_tables.
class CreateActiveAgentDraftPullRequests < ActiveRecord::Migration[7.2]
  def change
    prefix = ActionAgent.table_name_prefix

    create_table "#{prefix}draft_pull_requests" do |t|
      t.bigint :sandbox_session_id, null: false
      # "owner/name" on GitHub.
      t.string :repository, null: false
      # The branch the pull request merges into, and the branch published.
      t.string :base_branch
      t.string :branch, null: false
      # The commit the sandbox checked out, and the last commit published.
      t.string :base_commit, null: false
      t.string :head_commit
      t.string :title, null: false
      t.text :body
      # The message of the last update's commit.
      t.text :commit_message
      # The files of the last publish, each { path, status, mode, digest }.
      t.column :files, json_type, **json_default([])
      # What the last publish did ("create", "update", "open_draft",
      # "open_regular") and how it went ("queued", "publishing", "published",
      # "draft_refused", "failed").
      t.string :operation, null: false, default: "create"
      t.string :status, null: false, default: "queued"
      # Why the last publish failed: a word the dashboard acts on (see
      # DraftPullRequestPublisher::Refused), and a message for the user.
      t.string :error_code
      t.text :error_message
      # "app" (a GitHub App installation) or "oauth" (the OAuth connection).
      t.string :credential_kind
      t.integer :number
      t.string :url
      t.string :compare_url
      # "open", "closed" or "merged", and whether it is a draft, as GitHub
      # last reported them.
      t.string :state
      t.boolean :draft
      t.datetime :last_checked_at
      # The user who published, and the owner.
      t.bigint :user_id
      t.bigint :account_id
      t.timestamps
      t.index :sandbox_session_id, name: "index_#{prefix}draft_pull_requests_on_sandbox_session"
      t.index :account_id, name: "index_#{prefix}draft_pull_requests_on_account"
      t.index :user_id, name: "index_#{prefix}draft_pull_requests_on_user"
    end
  end

  private

  def json_type
    @json_type ||= postgres? ? :jsonb : :json
  end

  # MySQL rejects a default on a JSON column outright, so the column is
  # created without one there.
  def json_default(value, null: nil)
    return {} unless postgres?

    null.nil? ? { default: value } : { default: value, null: null }
  end

  def postgres?
    connection.adapter_name.to_s.downcase.include?("postgres")
  end
end
