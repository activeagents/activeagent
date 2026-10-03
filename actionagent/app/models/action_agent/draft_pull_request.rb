# frozen_string_literal: true

module ActionAgent
  # A pull request opened from a checkout sandbox's changes (see
  # DraftPullRequestPublisher), and how its last publish went.
  #
  # A publish is one of three operations:
  #
  #   create        a new branch and a draft pull request for it
  #   update        a new commit on the branch an earlier create published
  #   open_regular  a regular pull request for the branch of a create that
  #                 GitHub refused to open as a draft
  #
  # +status+ is how the last one went: queued, publishing, published,
  # draft_refused (the branch was pushed, the draft was not opened) or
  # failed. A publish still queued or publishing STALL_AFTER after its last
  # write is failed as stalled by .fail_stalled!. +state+ and +draft+ are
  # what GitHub last reported about the pull request, read again at most
  # once per STATUS_REFRESH_INTERVAL.
  #
  # The +user_id+ is the user who published, also where the owner is the
  # account.
  class DraftPullRequest < ApplicationRecord
    include Ownable
    owned_by :account, :user

    OPERATIONS = %w[create update open_regular].freeze
    STATUSES = %w[queued publishing published draft_refused failed].freeze
    CREDENTIAL_KINDS = %w[app oauth].freeze
    STATES = %w[open closed merged].freeze
    STATUS_REFRESH_INTERVAL = 1.minute
    STALL_AFTER = 15.minutes
    DEFAULT_UPDATE_MESSAGE = "Update from the sandbox"
    MAX_TITLE_CHARACTERS = 256
    MAX_BODY_CHARACTERS = 20_000

    belongs_to :sandbox_session

    validates :repository, :branch, :base_commit, :title, presence: true
    validates :title, length: { maximum: MAX_TITLE_CHARACTERS }
    validates :body, :commit_message, length: { maximum: MAX_BODY_CHARACTERS }
    validates :operation, inclusion: { in: OPERATIONS }
    validates :status, inclusion: { in: STATUSES }
    validates :credential_kind, inclusion: { in: CREDENTIAL_KINDS }, allow_nil: true
    validates :state, inclusion: { in: STATES }, allow_nil: true

    scope :recent, -> { order(created_at: :desc, id: :desc) }

    # Fails every publish of the relation that is still queued or publishing
    # STALL_AFTER after it was last written: its job died, or never ran.
    #
    # @return [Integer] how many were failed
    def self.fail_stalled!(now: Time.current)
      where(status: %w[queued publishing]).where(updated_at: ...(now - STALL_AFTER)).update_all(
        status: "failed", error_code: "stalled", updated_at: now,
        error_message: "The publish did not finish within #{STALL_AFTER.inspect}. Check the branch on GitHub, then publish again"
      )
    end

    # JSON columns carry no default on MySQL or SQLite (see the migration).
    def files
      Array(super)
    end

    # Whether the last publish is still to run or running.
    def in_progress?
      status.in?(%w[queued publishing])
    end

    # Whether the pull request exists on GitHub.
    def opened?
      number.present?
    end

    # The user who published, under the host's user model, or nil.
    def publisher
      user_class = ActionAgent.user_class&.safe_constantize
      user_class && user_id ? user_class.find_by(id: user_id) : nil
    end

    # Claims the next status refresh for the caller when the last one is at
    # least STATUS_REFRESH_INTERVAL old: true for exactly one of any callers
    # racing for it.
    def claim_status_refresh!(now: Time.current)
      return false unless opened?

      claimed = self.class.where(id: id)
        .where("last_checked_at IS NULL OR last_checked_at < ?", now - STATUS_REFRESH_INTERVAL)
        .update_all(last_checked_at: now)
      self.last_checked_at = now if claimed == 1
      claimed == 1
    end

    def summary
      {
        id: id,
        sandbox_session_id: sandbox_session&.session_id,
        repository: repository,
        base_branch: base_branch,
        branch: branch,
        base_commit: base_commit,
        head_commit: head_commit,
        title: title,
        body: body,
        files: files.map { |file| file.slice("path", "status", "mode") },
        operation: operation,
        status: status,
        error_code: error_code,
        error_message: error_message,
        credential_kind: credential_kind,
        number: number,
        url: url,
        compare_url: compare_url,
        state: state,
        draft: draft,
        last_checked_at: last_checked_at&.iso8601,
        created_at: created_at&.iso8601,
        updated_at: updated_at&.iso8601
      }
    end
  end
end
