# frozen_string_literal: true

module ActionAgent
  # A walk through a project's running app, and the candidate evaluation
  # scenarios it proposed for a person to review.
  #
  # The engine's explorer agent (source "explorer") or an agent outside the
  # dashboard (source "external", through the MCP facade's
  # `explorations_submit` tool) proposes candidates with #add_candidates!,
  # the only path that stores them. A reviewer edits or rejects them with
  # #update_candidate! and accepts them with #accept!, which merges them into
  # the target evaluation under keys x<exploration id>_<candidate id> and
  # never touches another scenario.
  #
  # Each candidate is a JSON object:
  #
  #   id             unique within the exploration, counting from 1
  #   prompt         the question a user would ask the target agent
  #   group          the scenario group it joins, DEFAULT_GROUP when none
  #   notes          the rubric: what a good answer does. The judge grades
  #                  the answer against it.
  #   expectations   { tools, contains, not_contains }
  #   verdict        answerable; needs_tool, with the expected tools the
  #                  target agent lacks in missing_tools; or unverified, when
  #                  its tools could not be read (see #tool_roster)
  #   missing_tools  see verdict
  #   state          proposed, edited, accepted or rejected
  #   scenario_key   the key it was last accepted under, or nil
  #   provenance     { urls, steps, recording_id, range: { from_ms, to_ms },
  #                  screenshots }: how it was found. Shown to the reviewer,
  #                  and never to the judge. recording_id and range are kept
  #                  only when they name this exploration's own
  #                  session_recording. The range is in milliseconds from
  #                  the recording's start.
  #
  # An explorer exploration is walked by ExplorerExecutionService within its
  # budget: { minutes, steps, cost }, where steps counts browser tool calls
  # and cost is in US dollars. Its usage counts the same. Running out of any
  # of them, or Stop and review, ends it in review with what it found.
  # Status moves from pending to running to review, or to failed. Review
  # becomes closed once no candidate awaits a decision, and review again
  # when one does.
  class Exploration < ApplicationRecord
    include Ownable
    owned_by :account, :user

    # Raised for a batch over MAX_BYTES, and for a batch or an edit that
    # would take the exploration past MAX_CANDIDATES or MAX_BYTES.
    class CandidateLimitExceeded < StandardError; end

    # Raised for a candidate that cannot be stored or changed as given.
    class InvalidCandidate < ArgumentError; end

    # Raised by #accept! when nothing can be accepted. #problems maps the id
    # of each refused candidate to why.
    class AcceptRefused < StandardError
      attr_reader :problems

      def initialize(message, problems = {})
        super(message)
        @problems = problems
      end
    end

    STATUSES = %w[pending running review closed failed].freeze
    SOURCES = %w[explorer external].freeze
    # The states of a candidate still awaiting a decision.
    OPEN_STATES = %w[proposed edited].freeze
    EXPECTATION_KEYS = %w[tools contains not_contains].freeze
    BUDGET_KEYS = %w[minutes steps cost].freeze
    MAX_CANDIDATES = 200
    # A candidate's prompt and rubric hold at most MAX_STRING characters,
    # and each expectation list at most MAX_ITEMS entries of at most
    # MAX_LABEL characters. A longer one is refused, because accepting the
    # candidate writes them into a scenario as they are. The group is a
    # label, cut to MAX_LABEL. Provenance is only shown to the reviewer, so
    # PayloadBounds cuts its strings to MAX_PROVENANCE_STRING characters
    # and its lists to MAX_ITEMS entries.
    MAX_STRING = 4_000
    MAX_ITEMS = 50
    MAX_LABEL = 200
    MAX_PROVENANCE_STRING = 2_048
    # The candidates one call submits, and all an exploration stores, are
    # at most this much JSON.
    MAX_BYTES = EvaluationReportImport::MAX_BYTES
    DEFAULT_GROUP = "Explored"
    # The explorer's budget when a start names none, and the most one may set.
    DEFAULT_BUDGET = { "minutes" => 15, "steps" => 150 }.freeze
    MAX_BUDGET = { "minutes" => 120, "steps" => 1_000, "cost" => 100 }.freeze
    # Credentials of each kind read for scrubbing.
    SECRET_LOOKUP_LIMIT = 100
    # A pattern containing one of these does not survive the suite editor,
    # whose line format splits on " | ", "," and ";".
    UNSAVEABLE_PATTERN = /[,;\r\n]|\s\|\s/

    belongs_to :project, class_name: "ActionAgent::Project", optional: true
    belongs_to :evaluation, class_name: "ActionAgent::Evaluation", optional: true
    belongs_to :agent_run, class_name: "ActionAgent::AgentRun", optional: true
    belongs_to :sandbox_session, class_name: "ActionAgent::SandboxSession", optional: true
    belongs_to :session_recording, class_name: "ActionAgent::SessionRecording", optional: true

    validates :status, inclusion: { in: STATUSES }
    validates :source, inclusion: { in: SOURCES }
    validates :start_url, length: { maximum: 2048 }, allow_nil: true
    validate :project_or_evaluation

    scope :recent, -> { order(created_at: :desc, id: :desc) }

    # An unsaved exploration of +project+, or of +evaluation+ when there is
    # no project. An evaluation that is a project's own evaluation makes it
    # that project's exploration. A project's exploration carries the
    # project's owner columns, and an evaluation's carries +user+'s and
    # +account+'s, the caller's.
    def self.build_for(project: nil, evaluation: nil, user: nil, account: nil, **attributes)
      if project.nil? && evaluation
        owning = Project.for_evaluation(evaluation)
        project = owning if owning && owning.evaluation_id == evaluation.id
      end
      evaluation = nil if project && evaluation&.id != project.evaluation_id

      exploration = new(project: project, evaluation: evaluation, start_url: project&.start_url, **attributes)
      if project
        exploration.account_id = project.account_id
        exploration.user_id = project.user_id
      else
        exploration.user_id = user.id if ActionAgent.user_class.present? && user.respond_to?(:id)
        exploration.account_id = account.id if account
      end
      exploration
    end

    # The verdict for a candidate expecting +tools+, as
    # { "verdict", "missing_tools" }, against +roster+ (see #tool_roster).
    # A tool missing from a roster that lacks a failed server's tools is
    # unverified rather than missing.
    def self.verdict(tools, roster)
      return { "verdict" => "unverified", "missing_tools" => [] } if roster.nil?

      missing = Array(tools) - roster[:names].to_a
      return { "verdict" => "answerable", "missing_tools" => [] } if missing.empty?
      return { "verdict" => "unverified", "missing_tools" => [] } unless roster[:complete]

      { "verdict" => "needs_tool", "missing_tools" => missing }
    end

    # The line ScenarioSuitePanel's Save writes for +entry+ (a scenario's
    # key, prompt, notes and expectations), which ScenarioParser reads back.
    # Mirrors scenarioLine in frontend/utils/scenarioSuiteText.mjs; both are
    # checked against frontend/test/fixtures/suite-editor-lines.json.
    def self.suite_editor_line(entry)
      expectations = entry["expectations"] || {}
      options = EXPECTATION_KEYS.filter_map do |field|
        values = Array(expectations[field])
        "#{field}: #{values.join(', ')}" if values.any?
      end
      options << "notes: #{entry['notes']}" if entry["notes"].present?
      options << "key: #{entry['key']}"
      "#{entry['prompt']} | #{options.join(' | ')}"
    end

    # MySQL cannot give a JSON column a default, so an unset column reads nil.
    def budget
      super || {}
    end

    def usage
      super || {}
    end

    def candidates
      super || []
    end

    # The agent candidates are checked against and accepted scenarios replay
    # through: the project's target agent, or the evaluation's agent.
    def target_agent
      project ? project.target_agent : evaluation&.agent
    end

    # The evaluation accepted candidates merge into: the project's
    # evaluation on its target agent, or this exploration's when it has no
    # project. Nil when a project has none, because no target agent is
    # chosen, its evaluation was deleted or it is on another agent. The
    # project's next accept then creates one.
    def target_evaluation
      return evaluation unless project

      current = project.evaluation
      current if current && current.agent_id == project.target_agent_id
    end

    # The project whose app the candidates come from: this exploration's,
    # or the project whose target agent its evaluation belongs to (see
    # Project.for_evaluation). Nil for an evaluation of any other agent.
    #
    # @return [Project, nil]
    def app_project
      project || Project.for_evaluation(evaluation)
    end

    # The target agent's tools as verdicts read them: { names:, complete: },
    # where complete is false when one of the agent's own servers failed
    # discovery. An exploration of a project's app (see #app_project) reads
    # the app's tools from the project's current sandbox, and the browser's
    # while the sandbox runs one, as the project's evaluation runs reach it.
    #
    # Nil when the tools cannot be read: there is no target agent, the
    # project has no sandbox, or its sandbox is not live or did not answer.
    #
    # @return [Hash, nil]
    def tool_roster
      agent = target_agent or return nil
      extra = []
      if (source = app_project)
        sandbox = source.current_sandbox_session or return nil
        extra << sandbox.runtime_server_key
        extra << sandbox.browser_server_key if sandbox.browser_running?
      end

      roster = RuntimeToolRoster.new(agent, extra_server_keys: extra)
      { names: roster.tools.keys.to_set, complete: roster.discovery_errors.empty? }
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] exploration #{id || 'new'}: could not read the target agent's tools: #{e.class}")
      nil
    end

    # Saves this new exploration with +list+ as its first candidates (see
    # #add_candidates!). Nothing is saved when the candidates are refused.
    #
    # @return [Array<Hash>] the stored candidates
    def save_with_candidates!(list)
      roster = tool_roster
      transaction do
        save!
        add_candidates!(list, roster: roster)
      end
    end

    # Stores +list+ as proposed candidates and returns them as stored. Each
    # entry is a candidate's prompt, group, notes (or rubric), expectations
    # (or top-level tools, contains and not_contains) and provenance. Each
    # is scrubbed of the values #scrub_secrets lists, checked against the
    # size limits (see MAX_STRING) and given a verdict against +roster+.
    #
    # Nothing is stored when an entry is invalid, +list+ is more than
    # MAX_BYTES of JSON, or the exploration would hold more than
    # MAX_CANDIDATES or MAX_BYTES.
    #
    # @param roster [Hash, nil, :read] see #tool_roster; :read reads it
    # @raise [InvalidCandidate]
    # @raise [CandidateLimitExceeded]
    # @return [Array<Hash>]
    def add_candidates!(list, roster: :read)
      raise InvalidCandidate, "candidates must be a list of objects" unless list.is_a?(Array)
      raise InvalidCandidate, "give at least one candidate" if list.empty?
      raise CandidateLimitExceeded, "An exploration holds at most #{MAX_CANDIDATES} candidates" if list.size > MAX_CANDIDATES
      if list.to_json.bytesize > MAX_BYTES
        raise CandidateLimitExceeded, "The candidates in one call may total #{MAX_BYTES / 1.megabyte} MiB of JSON: " \
                                      "give them over several calls"
      end

      secrets = scrub_secrets
      prepared = list.each_with_index.map { |raw, index| prepare_candidate(raw, label: "Candidate #{index + 1}", secrets: secrets) }
      roster = tool_roster if roster == :read

      stored = with_lock do
        current = candidates
        if current.size + prepared.size > MAX_CANDIDATES
          raise CandidateLimitExceeded, "An exploration holds at most #{MAX_CANDIDATES} candidates: this one holds " \
                                        "#{current.size} and these are #{prepared.size} more"
        end

        next_id = current.map { |candidate| candidate["id"].to_i }.max.to_i + 1
        rows = prepared.each_with_index.map do |candidate, offset|
          candidate.merge("id" => next_id + offset, "state" => "proposed", "scenario_key" => nil)
            .merge(self.class.verdict(candidate.dig("expectations", "tools"), roster))
        end
        refuse_oversized_list!(current + rows, "submit these as a new exploration")
        self.candidates = current + rows
        self.status = "review" if status == "closed"
        save!
        rows
      end
      broadcast_change
      stored
    end

    # Changes candidate +id+ and returns it. +attributes+ may carry:
    #
    #   prompt, group, notes (or rubric), tools, contains, not_contains
    #       an edit, stored the way #add_candidates! stores a candidate.
    #       The state becomes "edited", and changed tools are checked
    #       against the roster again. An accepted candidate keeps its
    #       scenario key, and accepting it again updates that scenario.
    #   state
    #       "rejected", or "proposed" to reconsider a rejected candidate.
    #       An accepted candidate cannot be rejected: its scenario is in the
    #       evaluation, and is disabled or deleted there.
    #
    # @raise [ActiveRecord::RecordNotFound] when there is no candidate +id+
    # @raise [InvalidCandidate]
    # @raise [CandidateLimitExceeded]
    # @return [Hash]
    def update_candidate!(id, attributes)
      attributes = plain_hash(attributes)
      state = attributes.delete("state")&.to_s
      if state && !%w[rejected proposed].include?(state)
        raise InvalidCandidate, "state must be rejected, or proposed to reconsider a rejected candidate"
      end

      edits = attributes.slice("prompt", "group", "notes", "rubric", "expectations", *EXPECTATION_KEYS)
      secrets = edits.any? ? scrub_secrets : []
      roster = edits_tools?(edits) ? tool_roster : nil

      updated = with_lock do
        rows = candidates.deep_dup
        candidate = rows.find { |row| row["id"] == id.to_i } or raise ActiveRecord::RecordNotFound, "No candidate #{id}"

        if edits.any?
          apply_edit!(candidate, edits, roster: roster, secrets: secrets)
          refuse_oversized_list!(rows, "shorten the edit")
        end
        case state
        when "rejected"
          if candidate["scenario_key"].present?
            raise InvalidCandidate, "Candidate #{candidate['id']} was accepted as #{candidate['scenario_key']}: disable or " \
                                    "delete that scenario in the evaluation instead"
          end
          candidate["state"] = "rejected"
        when "proposed"
          candidate["state"] = "proposed" if candidate["state"] == "rejected"
        end

        self.candidates = rows
        settle_status
        save!
        candidate
      end
      broadcast_change
      updated
    end

    # Merges candidates +ids+ into the target evaluation, marks them
    # accepted and returns Evaluation#merge_scenarios!'s keys with the
    # evaluation under :evaluation. Each becomes the scenario
    # x<exploration id>_<candidate id>, written as the suite editor saves it
    # (see #suite_entry): the rubric as its notes, folded onto one line.
    # Accepting a candidate again updates its scenario. A project's first
    # accept creates the project's evaluation on its target agent.
    #
    # +edits+ maps a candidate id to an edit, as #update_candidate! takes
    # one, applied first.
    #
    # Nothing is written when any candidate is refused: a rejected one
    # (reconsider it first), one the suite editor cannot save unchanged, or
    # one whose key a scenario from outside this exploration already holds.
    #
    # @raise [AcceptRefused]
    # @raise [InvalidCandidate] for an edit, as #update_candidate! raises it
    # @raise [CandidateLimitExceeded]
    # @raise [Evaluation::ScenarioLimitExceeded]
    # @return [Hash]
    def accept!(ids, edits: {})
      ids = Array(ids).map { |id| Integer(id.to_s, exception: false) }
      raise AcceptRefused, "Choose the candidates to accept" if ids.empty?
      raise AcceptRefused, "Candidate ids are numbers" if ids.include?(nil)

      ids = ids.uniq
      edits = plain_hash(edits).each_with_object({}) do |(id, edit), map|
        number = Integer(id.to_s, exception: false) or raise AcceptRefused, "Candidate ids are numbers"
        map[number] = plain_hash(edit).slice("prompt", "group", "notes", "rubric", "expectations", *EXPECTATION_KEYS)
      end
      secrets = edits.any? ? scrub_secrets : []
      roster = edits.values.any? { |edit| edits_tools?(edit) } ? tool_roster : nil

      result = with_lock do
        agent = target_agent or raise AcceptRefused, project ? "Choose the agent to evaluate first" : "The evaluation no longer exists"

        rows = candidates.deep_dup
        by_id = rows.index_by { |row| row["id"] }
        unknown = ids.reject { |id| by_id.key?(id) }
        raise AcceptRefused, "No candidate #{unknown.join(', ')}" if unknown.any?

        problems = {}
        entries = ids.filter_map do |id|
          candidate = by_id[id]
          if candidate["state"] == "rejected"
            problems[id] = "it was rejected: reconsider it first"
            next
          end

          apply_edit!(candidate, edits[id], roster: roster, secrets: secrets) if edits[id].present?
          entry, problem = suite_entry(candidate)
          problems[id] = problem if problem
          entry
        end
        raise AcceptRefused.new("Some candidates cannot be accepted", problems) if problems.any?

        refuse_oversized_list!(rows, "shorten the edits") if edits.any?

        evaluation = accept_evaluation!(agent)
        refuse_held_keys!(evaluation, entries, by_id)
        merged = evaluation.merge_scenarios!(entries, limit: EvaluationReportImport::MAX_SCENARIOS_PER_EVALUATION)

        entries.each do |entry|
          candidate = by_id.fetch(entry["candidate_id"])
          candidate["state"] = "accepted"
          candidate["scenario_key"] = entry["key"]
        end
        self.candidates = rows
        self.evaluation_id ||= evaluation.id
        settle_status
        save!
        merged.merge(evaluation: evaluation)
      end
      broadcast_change
      result
    end

    # Ends a pending or running exploration, keeping the candidates found so
    # far for review. It is closed when none awaits a decision.
    #
    # @return [Boolean] whether it was pending or running
    def stop!(reason: "stopped")
      stopped = with_lock do
        next false unless %w[pending running].include?(status)

        assign_attributes(status: "review", stop_reason: reason, finished_at: Time.current)
        settle_status
        save!
        true
      end
      broadcast_change if stopped
      stopped
    end

    # Whether the exploration may still add candidates on its own.
    def active?
      %w[pending running].include?(status)
    end

    # The explorer budget +raw+ asks for (minutes, steps and an optional
    # cost), with DEFAULT_BUDGET's limits where it names none.
    #
    # @raise [InvalidCandidate] for a limit that is not a positive number,
    #   or above MAX_BUDGET
    # @return [Hash{String => Numeric}]
    def self.budget_from(raw)
      raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
      raw = raw.is_a?(Hash) ? raw.stringify_keys.slice(*BUDGET_KEYS).compact_blank : {}
      budget = DEFAULT_BUDGET.merge(raw.to_h do |key, value|
        number = key == "cost" ? Float(value.to_s, exception: false) : Integer(value.to_s, exception: false)
        unless number&.positive? && number <= MAX_BUDGET.fetch(key)
          raise InvalidCandidate, "The #{key} budget must be a number above 0 and at most #{MAX_BUDGET.fetch(key)}"
        end

        [ key, number ]
      end)
      budget
    end

    # Marks the explorer's walk started, with nothing used yet.
    def start_walk!
      update!(status: "running", started_at: Time.current, usage: { "minutes" => 0, "steps" => 0, "cost" => 0 })
      broadcast_change
    end

    # Stores the walk's usage so far ({ minutes, steps, cost }).
    def record_usage!(minutes:, steps:, cost:)
      update_columns(usage: { "minutes" => minutes.round(2), "steps" => steps, "cost" => cost.round(4) }, updated_at: Time.current)
    end

    # Ends a running walk for review with what it found, unless it was
    # stopped meanwhile. +reason+ becomes the stop_reason: "finished",
    # "budget_minutes", "budget_steps", "budget_cost" or "stopped".
    #
    # @return [Boolean] whether it was running
    def finish_walk!(reason:)
      stop!(reason: reason)
    end

    # Ends a pending or running walk as failed, keeping its candidates for
    # review. +message+ is stored scrubbed of the values #scrub_secrets lists.
    def fail_walk!(message)
      failed = with_lock do
        next false unless active?

        update!(status: "failed", stop_reason: "error", error_message: SecretScrubber.scrub(message.to_s, scrub_secrets).truncate(2_000),
          finished_at: Time.current)
        true
      end
      broadcast_change if failed
      failed
    end

    # Whether the walk is still meant to go on: false once it was stopped,
    # failed or reviewed. Reads the stored status.
    def walking?
      self.class.where(id: id, status: "running").exists?
    end

    def candidate_counts
      list = candidates
      {
        total: list.size,
        open: list.count { |candidate| OPEN_STATES.include?(candidate["state"]) },
        accepted: list.count { |candidate| candidate["state"] == "accepted" },
        rejected: list.count { |candidate| candidate["state"] == "rejected" },
        answerable: list.count { |candidate| candidate["verdict"] == "answerable" },
        needs_tool: list.count { |candidate| candidate["verdict"] == "needs_tool" },
        unverified: list.count { |candidate| candidate["verdict"] == "unverified" }
      }
    end

    def summary
      {
        id: id,
        project_id: project_id,
        evaluation_id: evaluation_id,
        agent_run_id: agent_run_id,
        session_recording_id: session_recording_id,
        source: source,
        status: status,
        stop_reason: stop_reason,
        error_message: error_message,
        start_url: start_url,
        budget: budget.slice(*BUDGET_KEYS),
        usage: usage.slice(*BUDGET_KEYS),
        counts: candidate_counts,
        started_at: started_at&.iso8601,
        finished_at: finished_at&.iso8601,
        created_at: created_at&.iso8601,
        updated_at: updated_at&.iso8601
      }
    end

    # The values candidate text is scrubbed of: the secrets of the project
    # whose app it comes from (see #app_project) with their encodings, the
    # owner's provider keys, GitHub token and API keys, and the runtime and
    # browser tokens of that project's sandboxes.
    #
    # @return [Array<String>]
    def scrub_secrets
      owner_record = owner
      source = app_project
      sandbox_tokens = source ? SandboxSession.where(project_id: source.id).order(id: :desc).limit(SECRET_LOOKUP_LIMIT)
        .pluck(:runtime_mcp_token, :browser_token).flatten.compact : []

      [
        *(source ? source.scrub_values : []),
        *ProviderKey.for_owner(owner_record).limit(SECRET_LOOKUP_LIMIT).pluck(:credential, :api_key).flatten,
        *GithubConnection.for_owner(owner_record).limit(SECRET_LOOKUP_LIMIT).pluck(:access_token),
        *ApiKey.for_owner(owner_record).limit(SECRET_LOOKUP_LIMIT).pluck(:token),
        *sandbox_tokens
      ].compact
    end

    private

    def project_or_evaluation
      errors.add(:base, "An exploration needs a project or an evaluation") if project_id.nil? && evaluation_id.nil?
    end

    def broadcast_change
      LiveUpdates.broadcast("exploration_#{id}", type: "exploration", id: id, status: status)
    end

    # review and closed follow the candidates: closed once none awaits a
    # decision.
    def settle_status
      return unless %w[review closed].include?(status)

      self.status = candidates.any? { |candidate| OPEN_STATES.include?(candidate["state"]) } ? "review" : "closed"
    end

    def plain_hash(value)
      value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
      value.is_a?(Hash) ? value.deep_stringify_keys : {}
    end

    def edits_tools?(edit)
      edit.key?("tools") || (edit["expectations"].is_a?(Hash) && edit["expectations"].stringify_keys.key?("tools"))
    end

    # Applies +edit+ to +candidate+ in place, as a reviewer's edit. The
    # provenance is not editable and is kept as stored.
    def apply_edit!(candidate, edit, roster:, secrets:)
      before = candidate.dig("expectations", "tools")
      edit = edit.merge("notes" => edit["rubric"]) if edit.key?("rubric") && !edit.key?("notes")
      merged = candidate.slice("prompt", "group", "notes", "expectations").merge(edit.except("expectations", "rubric"))
      if edit["expectations"].is_a?(Hash)
        merged["expectations"] = candidate["expectations"].to_h.merge(edit["expectations"].stringify_keys)
      end
      prepared = prepare_candidate(merged, label: "Candidate #{candidate['id']}", secrets: secrets).except("provenance")

      candidate.merge!(prepared)
      candidate.merge!(self.class.verdict(prepared.dig("expectations", "tools"), roster)) if prepared.dig("expectations", "tools") != before
      candidate["state"] = "edited"
      candidate
    end

    # A candidate from +raw+, scrubbed of +secrets+ and checked against the
    # size limits (see MAX_STRING). The group and provenance are cut after
    # scrubbing, so a cut never leaves part of a secret behind.
    def prepare_candidate(raw, label:, secrets:)
      raw = plain_hash(raw) if raw.respond_to?(:to_unsafe_h) || raw.is_a?(Hash)
      raise InvalidCandidate, "#{label} must be an object" unless raw.is_a?(Hash)

      expectations = raw["expectations"].is_a?(Hash) ? raw["expectations"].stringify_keys : {}
      candidate = SecretScrubber.scrub({
        "prompt" => text(raw["prompt"]).strip,
        "group" => text(raw["group"]).strip,
        "notes" => text(raw.key?("notes") ? raw["notes"] : raw["rubric"]).strip.presence,
        "expectations" => EXPECTATION_KEYS.index_with { |field| string_list(raw.key?(field) ? raw[field] : expectations[field]) },
        "provenance" => provenance(raw["provenance"])
      }, secrets)
      raise InvalidCandidate, "#{label} has no prompt" if candidate["prompt"].empty?

      refuse_oversized_fields!(candidate, label)
      candidate.merge(
        "group" => candidate["group"].first(MAX_LABEL).presence || DEFAULT_GROUP,
        "provenance" => PayloadBounds.bound(candidate["provenance"], max_string: MAX_PROVENANCE_STRING, max_items: MAX_ITEMS)
      )
    end

    def refuse_oversized_fields!(candidate, label)
      { "prompt" => "prompt", "notes" => "rubric" }.each do |field, name|
        next if candidate[field].to_s.length <= MAX_STRING

        raise InvalidCandidate, "#{label}: the #{name} is longer than #{MAX_STRING} characters"
      end
      candidate["expectations"].each do |field, values|
        name = field.tr("_", " ")
        raise InvalidCandidate, "#{label} has more than #{MAX_ITEMS} #{name} entries" if values.size > MAX_ITEMS
        if (long = values.find { |value| value.length > MAX_LABEL })
          raise InvalidCandidate, "#{label}: #{name} “#{long.truncate(60)}” is longer than #{MAX_LABEL} characters"
        end
      end
    end

    # Raises when +rows+, all of an exploration's candidates, are more than
    # MAX_BYTES of JSON. The message ends with +remedy+.
    def refuse_oversized_list!(rows, remedy)
      return if rows.to_json.bytesize <= MAX_BYTES

      raise CandidateLimitExceeded, "An exploration's candidates may total #{MAX_BYTES / 1.megabyte} MiB of JSON, and " \
                                    "this would take this one past it: #{remedy}"
    end

    # A submitter names a recording by id, so one that is not this
    # exploration's is dropped with its range: a replay link must only ever
    # open the recording of this walk.
    def provenance(raw)
      raw = plain_hash(raw)
      return {} if raw.empty?

      recording_id = integer(raw["recording_id"])
      recording_id = nil unless recording_id && recording_id == session_recording_id
      range = recording_id ? plain_hash(raw["range"]) : {}
      {
        "urls" => string_list(raw.key?("urls") ? raw["urls"] : raw["url"]),
        "steps" => string_list(raw["steps"]),
        "recording_id" => recording_id,
        "range" => { "from_ms" => integer(range["from_ms"]), "to_ms" => integer(range["to_ms"]) }.compact.presence,
        "screenshots" => string_list(raw["screenshots"])
      }.compact
    end

    def text(value)
      value.is_a?(String) || value.is_a?(Numeric) ? value.to_s : ""
    end

    def string_list(value)
      Array(value).filter_map { |item| text(item).strip.presence }.uniq
    end

    def integer(value)
      return value if value.is_a?(Integer)

      value.to_s.match?(/\A\d+\z/) ? value.to_i : nil
    end

    # [entry, problem]: the scenario attributes +candidate+ is accepted as,
    # or why it cannot be. The suite editor saves a suite as one line per
    # scenario and ScenarioParser reads the lines back, so the entry is
    # written the way that round trip leaves it: the prompt, group and rubric
    # folded onto one line with " | " written " / ", and the prompt without
    # the Markdown the parser drops. A pattern the parser would split, and
    # anything else the round trip would change, is refused.
    def suite_entry(candidate)
      expectations = {}
      EXPECTATION_KEYS.each do |field|
        values = Array(candidate.dig("expectations", field))
        if (bad = values.find { |value| value.match?(UNSAVEABLE_PATTERN) })
          return [ nil, "#{field.tr('_', ' ')} “#{bad.truncate(60)}” has a comma, semicolon, | or line break, which the " \
                        "suite editor splits on" ]
        end
        expectations[field] = values if values.any?
      end

      prompt = suite_text(candidate["prompt"], markup: true)
      return [ nil, "the prompt is empty" ] if prompt.empty?

      entry = {
        "key" => "x#{id}_#{candidate['id']}",
        "prompt" => prompt,
        "group" => suite_text(candidate["group"]).presence || DEFAULT_GROUP,
        "notes" => suite_text(candidate["notes"]).presence,
        "expectations" => expectations
      }
      unless survives_suite_editor?(entry)
        return [ nil, "the suite editor would change it when saving: check the prompt and rubric for Markdown or a " \
                      "line that reads as a heading" ]
      end

      [ entry.merge("candidate_id" => candidate["id"]), nil ]
    end

    def suite_text(value, markup: false)
      folded = value.to_s.gsub(/\s+/, " ").strip.gsub(" | ", " / ")
      return folded unless markup

      folded.gsub(/\*\*|__|`/, "").sub(ActiveAgent::Evals::ScenarioParser::LIST_MARKER, "").sub(/\A#+\s+/, "").strip
    end

    def survives_suite_editor?(entry)
      text = "# #{entry['group']}\n#{self.class.suite_editor_line(entry)}"
      parsed = ActiveAgent::Evals::ScenarioParser.parse(text)
      parsed.size == 1 &&
        parsed.first.values_at("key", "prompt", "group", "notes", "expectations") ==
          entry.values_at("key", "prompt", "group", "notes", "expectations")
    rescue ActiveAgent::Evals::ScenarioParser::ParseError
      false
    end

    def accept_evaluation!(agent)
      return evaluation || raise(AcceptRefused, "The evaluation no longer exists") unless project

      project.scenario_evaluation!(agent)
    end

    # Raises when a scenario this exploration did not accept holds one of
    # the keys +entries+ would write.
    def refuse_held_keys!(evaluation, entries, by_id)
      held = evaluation.scenarios.where(key: entries.map { |entry| entry["key"] }).pluck(:key).map(&:downcase).to_set
      problems = entries.each_with_object({}) do |entry, map|
        next unless held.include?(entry["key"].downcase)
        next if by_id.fetch(entry["candidate_id"])["scenario_key"].to_s.casecmp?(entry["key"])

        map[entry["candidate_id"]] = "the evaluation already has a scenario #{entry['key']} that this exploration did not add"
      end
      raise AcceptRefused.new("Some candidates cannot be accepted", problems) if problems.any?
    end
  end
end
