# frozen_string_literal: true

module ActionAgent
  # A question a paused run put to a person, and the answer the run resumes
  # with.
  #
  # A tool asks by returning an ActiveAgent::InputRequest, which ends the
  # generation paused. AgentRun#record_result! then stores one of these per
  # paused tool call. The requests of one pause share a `pause_key` and the
  # pause's checkpoint, and the run resumes (AgentResumeJob) once every one of
  # them is answered or declined.
  #
  # Statuses:
  #   - `pending`   waiting for a person
  #   - `answered`  answered; an answered `confirm` request is an approval
  #   - `declined`  declined; the paused tool does not run
  #   - `expired`   not answered before `expires_at`
  #   - `cancelled` the run was cancelled, or ended without the answer
  #
  # The owner columns are copied from the subject's agent when the request is
  # created. `answer` and `checkpoint` are encrypted at rest and are never
  # serialized (InputRequestSerializer).
  class InputRequest < ApplicationRecord
    include Ownable
    owned_by :account, :user

    # Raised when the request can no longer be answered or declined: it was
    # settled already, or it expired.
    class Conflict < StandardError; end

    # Raised when an answer does not fit the request.
    class InvalidAnswer < StandardError; end

    KINDS = ActiveAgent::InputRequest::KINDS.map(&:to_s).freeze
    # The answers that approve a `confirm` request, no answer among them, and
    # the answers that decline it.
    CONFIRM_APPROVALS = [ nil, true, "true" ].freeze
    CONFIRM_DECLINES = [ false, "false" ].freeze
    # The only subjects a request is created for. Later subjects join this list.
    SUBJECT_TYPES = %w[ActionAgent::AgentRun].freeze

    belongs_to :subject, polymorphic: true

    if ActionAgent.encrypt_credentials
      encrypts :answer
      encrypts :checkpoint
    end

    enum :status, { pending: 0, answered: 1, declined: 2, expired: 3, cancelled: 4 }

    validates :kind, inclusion: { in: KINDS }
    validates :subject_type, inclusion: { in: SUBJECT_TYPES }
    validates :prompt, :pause_key, presence: true

    before_validation :copy_owner_from_subject, on: :create

    scope :recent, -> { order(created_at: :desc, id: :desc) }

    # Stores the requests of one pause, sharing a pause key and the checkpoint
    # the run resumes from.
    #
    # @param subject [AgentRun] the paused run
    # @param requests [Array<ActiveAgent::InputRequest>] one per paused tool call
    # @param checkpoint [Hash] the paused response's checkpoint
    # @return [Array<InputRequest>]
    def self.record_pause!(subject, requests, checkpoint:)
      pause_key = SecureRandom.uuid
      stored_checkpoint = checkpoint.to_json
      expires_at = ActionAgent.input_request_ttl&.from_now
      requested_by_id = user_id_of(subject.try(:actor))

      requests.map do |request|
        create!(
          subject: subject,
          pause_key: pause_key,
          kind: request.kind.to_s,
          prompt: request.prompt,
          options: request.options,
          answer_schema: request.schema,
          tool_call_id: request.tool_call_id,
          tool_name: request.tool_name,
          arguments: request.kind.to_s == "confirm" ? request.metadata.to_h["arguments"] : nil,
          checkpoint: stored_checkpoint,
          expires_at: expires_at,
          requested_by_id: requested_by_id
        )
      end
    end

    # The id of +user+ when it is a record of the configured user class, so
    # an account or a service object is never stored as a person.
    def self.user_id_of(user)
      user_class = ActionAgent.user_class&.safe_constantize
      user.id if user_class && user.is_a?(user_class)
    end

    # The requests the same pause raised, this one included.
    # @return [ActiveRecord::Relation]
    def pause_requests
      self.class.where(subject_type: subject_type, subject_id: subject_id, pause_key: pause_key)
    end

    # Whether every request of the pause is answered or declined, so the run
    # can resume.
    def pause_settled?
      pause_requests.where.not(status: [ :answered, :declined ]).none?
    end

    # Whether this request belongs to the latest pause of its subject. A run
    # resumed from one pause may pause again, and then only the later pause's
    # checkpoint continues it.
    def current_pause?
      self.class.where(subject_type: subject_type, subject_id: subject_id).order(id: :desc).pick(:pause_key) == pause_key
    end

    # The checkpoint the pause stored, as a Hash.
    def checkpoint_data
      JSON.parse(checkpoint.to_s)
    end

    # What the paused tool call is dispatched again with: `false` for a
    # declined request, `true` for an approved `confirm`, the answer
    # otherwise.
    def resume_answer
      return false if declined?
      return true if kind == "confirm"

      answer
    end

    # The values a `choice` answer may take: each option, or its `value` when
    # the option is a hash.
    # @return [Array<String>]
    def choice_values
      Array(options).map { |option| option.is_a?(Hash) ? option.fetch("value", option["label"]) : option }.map(&:to_s)
    end

    # Whether +user+ may answer or decline this request. A multi-tenant
    # install refuses a request with no user, whatever the permission checker
    # says, so every answer names who gave it.
    def answerable_by?(user)
      return false if ActionAgent.multi_tenant? && user.nil?

      ActionAgent.permitted?(user, :answer_input_request, self)
    end

    # Answers the request, and enqueues AgentResumeJob when it was the last
    # of its pause to settle. A `confirm` request is approved by `true` or by
    # no answer, and declined by `false` (see #decline!), the way
    # ActiveAgent::InputRequest reads `false`.
    #
    # @param value [String, Boolean, nil] the answer
    # @param user [Object, nil] who answered
    # @raise [Conflict] when the request is no longer pending or has expired
    # @raise [InvalidAnswer] when the answer is blank, not text, not one of a
    #   `choice` request's options, or neither `true` nor `false` for a
    #   `confirm` request
    # @return [self]
    def answer!(value, user: nil)
      return decline!(user: user) if kind == "confirm" && CONFIRM_DECLINES.include?(value)

      settle!(:answered, value: value, user: user)
    end

    # Declines the request: its tool does not run, and the model reads an
    # error as the call's result.
    #
    # @raise [Conflict] when the request is no longer pending or has expired
    # @return [self]
    def decline!(user: nil)
      settle!(:declined, user: user)
    end

    private

    # Every settlement of a pause takes the subject's row lock, so two answers
    # to the same pause are applied one after the other and the second sees
    # the first. A failure is raised after the lock's transaction commits,
    # so an expiry it recorded is kept.
    def settle!(status, value: nil, user: nil)
      failure = nil
      resume = false

      subject.with_lock do
        reload
        failure = settle_failure(status, value)
        next if failure

        update!(
          status: status,
          answer: status == :answered && kind != "confirm" ? value.to_s : nil,
          answered_by_id: self.class.user_id_of(user),
          answered_at: Time.current
        )
        resume = pause_settled?
      end
      raise failure if failure

      AgentResumeJob.perform_later(id) if resume && subject.is_a?(AgentRun)
      self
    end

    def settle_failure(status, value)
      return Conflict.new("This request was already #{self.status}") unless pending?

      if expires_at&.past?
        expire_pause!
        return Conflict.new("This request expired at #{expires_at.iso8601}")
      end

      message = status == :answered ? answer_error(value) : nil
      InvalidAnswer.new(message) if message
    end

    # Marks this request expired and the rest of its pause cancelled, and
    # fails the run, which can no longer resume.
    def expire_pause!
      update!(status: :expired)
      pause_requests.pending.update_all(status: self.class.statuses[:cancelled], updated_at: Time.current)
      return unless subject.try(:awaiting_input?)

      subject.update!(status: :failed, completed_at: Time.current, error_message: "An input request expired before it was answered")
    end

    def answer_error(value)
      if kind == "confirm"
        return CONFIRM_APPROVALS.include?(value) ? nil : "Answer a confirm request with true or false"
      end

      return "Answer with text" unless value.is_a?(String) || value.is_a?(Numeric)
      return "An answer is required" if value.to_s.strip.empty?
      return nil unless kind == "choice"

      "#{value.to_s.truncate(64).inspect} is not one of the options" unless choice_values.include?(value.to_s)
    end

    def copy_owner_from_subject
      source = subject.respond_to?(:agent) ? subject.agent : subject
      return unless source

      self.account_id = source.try(:account_id)
      self.user_id = source.try(:user_id)
    end
  end
end
