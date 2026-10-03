# frozen_string_literal: true

require "etc"

module ActionAgent
  # A repository the dashboard boots in a checkout sandbox and evaluates an
  # agent against, without the repository having to install the engine first.
  #
  # A project keeps what every boot of the repository needs: the ref, the
  # start URL the second readiness probe requests, and its ProjectSecrets.
  # Each boot is a SandboxSession recorded as the project's current sandbox,
  # booted from #boot_spec (a bootstrap when the checkout lacks the engine).
  #
  # The project's target agent is a dashboard Agent the project owns, and the
  # project's evaluation belongs to it:
  #
  #   installed repository   a proxy for one of the checkout's own agents,
  #                          which answers through that agent's run_<slug>
  #                          tool on the sandbox's MCP facade
  #   any other repository   the "App assistant", whose tools are everything
  #                          the sandbox's facade serves
  #
  # Either way the agent's mcp_servers name the current sandbox, in place of
  # any earlier sandbox, and keep the servers added in the agent editor.
  #
  # A failed boot can start the project's setup assistant (ProjectSetup).
  #
  # The sandbox, the agent and the evaluation carry the project's own owner
  # columns, whoever starts a boot, so the agent's runs always reach the
  # project's sandbox (SandboxSession.runtime_server_entry looks among the
  # agent owner's sessions).
  class Project < ApplicationRecord
    include Ownable
    owned_by :account, :user

    # Raised by #ensure_sandbox! for a first boot on the :local backend that
    # nobody confirmed. Its message names the repository and the user the
    # code would run as.
    class ConfirmationRequired < StandardError; end
    # Raised by #ensure_sandbox! when no sandbox can be booted.
    class BootRefused < StandardError; end

    INSTALL_STATES = %w[detected bootstrapped installed].freeze
    REPOSITORY = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}
    APP_ASSISTANT_NAME = "App assistant"
    # The provider the App assistant runs on, first configured wins.
    ASSISTANT_PROVIDER_ORDER = %w[anthropic openai openrouter ollama].freeze
    # A run_<slug> tool on a checkout's MCP facade: one synced agent. Its
    # actions' tools are run_<slug>__<action>.
    SYNCED_AGENT_TOOL = /\Arun_(?<slug>(?:(?!__)[a-z0-9_-])+)\z/

    enum :status, { draft: "draft", booting: "booting", ready: "ready", failed: "failed" }

    belongs_to :current_sandbox_session, class_name: "ActionAgent::SandboxSession", optional: true
    belongs_to :target_agent, class_name: "ActionAgent::Agent", optional: true
    belongs_to :evaluation, class_name: "ActionAgent::Evaluation", optional: true
    has_many :secrets, class_name: "ActionAgent::ProjectSecret", dependent: :destroy
    has_many :sandbox_sessions, class_name: "ActionAgent::SandboxSession", dependent: :nullify

    validates :name, presence: true, length: { maximum: 100 }
    validates :repository, presence: true, format: { with: REPOSITORY, message: "must be owner/name" }
    validates :default_ref, length: { maximum: 255 }, format: { without: /\A-|\s|\.\./, message: "is not a valid git ref" },
      allow_blank: true
    validates :install_state, inclusion: { in: INSTALL_STATES }
    validate :start_url_is_a_path
    validate :name_unique_within_owner

    scope :recent, -> { order(updated_at: :desc, id: :desc) }

    # MySQL cannot give a JSON column a default, so an unset column reads nil.
    def settings
      super || {}
    end

    # The checkout's Gemfile.lock already bundles the engine.
    def engine_installed?
      install_state == "installed"
    end

    # How +sandbox+ boots: a bootstrap for a checkout whose Gemfile.lock
    # lacks the engine, and the checkout's own sandbox.yml boot otherwise
    # (the spec applies "without_engine"). Either way the project's secrets
    # reach the steps that run the repository's code, and a failed boot
    # keeps its workspace for SandboxOrchestrator#resume_boot.
    #
    # Built in memory each time: the secrets' values are read here, from the
    # encrypted column, and never stored with the boot.
    #
    # @raise [SandboxBootSpec::Invalid]
    # @raise [ActiveRecord::RecordNotFound] when a secret uses an
    #   organization key that is no longer stored
    def boot_spec(_sandbox = current_sandbox_session)
      SandboxBootSpec.bootstrap(apply: "without_engine", start_url: start_url, keep_on_failure: true,
        env: plain_environment, secrets: secret_environment)
    end

    # The ref a new sandbox checks out: default_ref, nil for the
    # repository's default branch.
    def checkout_ref
      default_ref.presence
    end
    # The setup assistant's state (see ProjectSetup):
    #
    #   agent_id         its dashboard Agent
    #   run_ids          the setup runs it started, newest last
    #   last_run_id      the latest of them
    #   retried_run_ids  the runs that retried the boot
    #   attempts         automatic runs since the last good boot
    #   auto             false when a failed boot starts no run on its own
    def setup_settings
      settings["setup"].is_a?(Hash) ? settings["setup"] : {}
    end

    def update_setup_settings!(values)
      update!(settings: settings.merge("setup" => setup_settings.merge(values.stringify_keys)))
    end

    # Whether a failed boot starts the setup assistant on its own.
    def auto_setup?
      setup_settings["auto"] != false
    end

    def setup_agent
      id = setup_settings["agent_id"]
      id && Agent.find_by(id: id)
    end

    # The requests for input of runs of the project's setup assistant and of
    # the agent it evaluates.
    #
    # @return [ActiveRecord::Relation<InputRequest>]
    def input_requests
      agent_ids = [ setup_settings["agent_id"], target_agent_id ].compact
      return InputRequest.none if agent_ids.empty?

      InputRequest.where(subject_type: AgentRun.polymorphic_name, subject_id: AgentRun.where(agent_id: agent_ids).select(:id))
    end

    # #input_requests still waiting for a person and not past their expiry.
    def pending_input_requests
      expires_at = InputRequest.arel_table[:expires_at]
      input_requests.pending.where(expires_at.eq(nil).or(expires_at.gt(Time.current)))
    end

    # { name => value } for every secret, organization keys resolved, but
    # the values the setup assistant set, which are not secret.
    def secret_environment
      secrets.ordered.reject(&:plain?).to_h { |secret| [ secret.name, secret.resolved_value.to_s ] }
    end

    # { name => value } for the values the setup assistant set (see
    # ProjectSecret), which are not secret, so a boot leaves them unmasked.
    def plain_environment
      secrets.ordered.select(&:plain?).to_h { |secret| [ secret.name, secret.value.to_s ] }
    end


    # The project's secret +name+ set as asked, unsaved: a new secret, or the
    # existing one with its value or source replaced. +set_by+ is recorded
    # as who set it.
    #
    # @param source [String] "entered" (with +value+), or "organization_key"
    #   (with +consent+, see ProjectSecret)
    # @return [ProjectSecret]
    def assign_secret(name:, value: nil, source: nil, consent: false, set_by: nil)
      secret = secrets.find_or_initialize_by(name: name.to_s)
      secret.account_id = account_id
      secret.user_id = user_id
      secret.set_by_id = set_by.try(:id)
      if source.to_s == "organization_key"
        secret.assign_attributes(source: "organization_key", provider: ProjectSecret::ORGANIZATION_KEY_PROVIDERS[name.to_s],
          value: nil, consented_at: consent ? Time.current : nil)
      else
        text = value.is_a?(String) || value.is_a?(Numeric) ? value.to_s : nil
        secret.assign_attributes(source: source.presence&.to_s || "entered", provider: nil, consented_at: nil, value: text)
      end
      secret
    end

    # What the project's sandboxes' output is scrubbed of: each secret's
    # value and its URL-encoded and Base64 forms. A secret whose
    # organization key is gone has no value to mask.
    #
    # @return [Array<String>]
    def scrub_values
      values = secrets.reject(&:plain?).filter_map do |secret|
        secret.resolved_value
      rescue ActiveRecord::RecordNotFound
        nil
      end
      SecretScrubber.with_encodings(values)
    end

    # The sandbox to run against: the current one while it is booting or
    # serving, the current one resumed when its failed boot was kept, or a
    # new one booted from #boot_spec.
    #
    # On the :local backend the first boot runs the repository's code as the
    # dashboard's own user, so it needs +confirm+ once (see
    # #local_boot_confirmation).
    #
    # @param confirm [Boolean] whether the caller confirmed a first :local boot
    # @param confirmed_by [Object, nil] the user who confirmed it
    # @param resume_from [String, nil] the step a kept boot resumes from,
    #   instead of the one that failed
    # @return [SandboxSession]
    # @raise [ConfirmationRequired]
    # @raise [BootRefused]
    # @raise [ActiveRecord::RecordInvalid] when the repository is no longer
    #   available to the owner's GitHub connection
    def ensure_sandbox!(confirm: false, confirmed_by: nil, orchestrator: SandboxOrchestrator.new, resume_from: nil)
      # Decided under the project's row lock, so two requests at once agree
      # on one sandbox. The boot is enqueued after the lock is released.
      sandbox, previous, action = with_lock do
        current = current_sandbox_session
        next [ current, nil, :live ] if current&.active?

        if current && resumable?(current, orchestrator)
          update!(status: "booting")
          next [ current, nil, :resume ]
        end

        unless orchestrator.accepts_boot_config?
          raise BootRefused, "The #{orchestrator.backend_name} sandbox backend cannot boot a project: it takes no boot spec"
        end
        confirm_local_boot!(orchestrator, confirm: confirm, confirmed_by: confirmed_by)
        [ create_sandbox!, current, :boot ]
      end

      case action
      when :live then sandbox
      when :resume
        return ensure_sandbox!(confirm: confirm, confirmed_by: confirmed_by, orchestrator: orchestrator) unless sandbox.resume_boot!(from: resume_from)

        LiveUpdates.broadcast(stream_name, type: "project", id: id, status: status)
        sandbox
      else
        previous.expire! if previous && !previous.expired?
        sandbox.provision!
        LiveUpdates.broadcast(stream_name, type: "project", id: id, status: status)
        sandbox
      end
    end

    # What a person has to confirm before the first boot on +orchestrator+,
    # or nil when nothing is asked: "This runs <owner/repo>'s code on this
    # machine as <user>."
    def local_boot_confirmation(orchestrator = SandboxOrchestrator.new)
      return nil unless orchestrator.local?
      return nil if settings["local_boot_confirmed_at"].present?

      "This runs #{repository}'s code on this machine as #{self.class.machine_user}."
    end

    def self.machine_user
      Etc.getpwuid(Process.uid)&.name || ENV["USER"].presence || "the dashboard's user"
    rescue StandardError
      ENV["USER"].presence || "the dashboard's user"
    end

    # Deletes the project with its target agent (and so its evaluation) and
    # its setup assistant, and stops its current sandbox.
    def discard!
      sandbox = current_sandbox_session
      transaction do
        agents = [ target_agent, setup_agent ].compact
        update_columns(target_agent_id: nil, evaluation_id: nil)
        agents.each(&:destroy!)
        destroy!
      end
      sandbox.expire! if sandbox && !sandbox.expired?
    end

    # Moves the project to +ref+ (nil for the repository's default branch),
    # which +preflight+ is ProjectPreflight's report on, saving any other
    # attribute assigned with it. The sandbox booted from the old ref is
    # stopped, so the next boot checks the new one out, and a ref whose lock
    # lacks the engine is evaluated with the App assistant.
    def change_ref!(ref, preflight)
      sandbox = current_sandbox_session
      transaction do
        update!(default_ref: ref, status: "draft", install_state: preflight["engine"] ? "installed" : "detected",
          settings: settings.merge("preflight" => preflight))
        ensure_app_assistant! unless engine_installed? || app_assistant?
      end
      sandbox.expire! if sandbox && !sandbox.expired?
      LiveUpdates.broadcast(stream_name, type: "project", id: id, status: status)
    end

    # Called by SandboxProvisionJob once +sandbox+ is serving. Ignored for a
    # sandbox that is no longer the current one.
    def sandbox_ready!(sandbox)
      settle!(sandbox) do
        attributes = { status: "ready" }
        attributes[:install_state] = "bootstrapped" if install_state == "detected"
        attributes.merge(settings: settings.merge("setup" => setup_settings.merge("attempts" => 0)))
      end
    end

    # Called by SandboxProvisionJob when +sandbox+'s boot failed. Starts the
    # setup assistant on it in the background, unless that is switched off
    # (see ProjectSetup.after_boot_failed).
    def sandbox_failed!(sandbox)
      changed = settle!(sandbox) { { status: "failed" } }
      ProjectSetupJob.perform_later(id, sandbox.id) if changed && auto_setup?
      changed
    end

    # Whether the target agent is the App assistant, as opposed to a proxy
    # for a synced agent.
    def app_assistant?
      target_agent.present? && settings["target_slug"].blank?
    end

    # Makes the App assistant the project's target agent, creating it and the
    # project's evaluation when missing.
    #
    # @return [Agent]
    def ensure_app_assistant!
      provider, model = self.class.assistant_model(owner)
      assign_target!(
        name: "#{APP_ASSISTANT_NAME} for #{repository}".truncate(100),
        description: "Answers questions about #{repository} with the tools its sandbox serves.",
        instructions: <<~TEXT,
          You are the assistant for #{repository}, a Rails application running in a sandbox.
          Answer by calling the application's tools. Never guess at data a tool can look up, and
          say so when no tool can answer the question.
        TEXT
        provider: provider, model: model, slug: nil, tools: nil
      )
    end

    # Makes a proxy for the checkout's agent +slug+ the project's target
    # agent: it answers by calling run_<slug> and nothing else.
    #
    # @return [Agent]
    def target_synced_agent!(slug)
      provider, model = self.class.assistant_model(owner)
      assign_target!(
        name: "#{repository} #{slug} (sandbox)".truncate(100),
        description: "Evaluates #{repository}'s #{slug} agent through its sandbox.",
        instructions: <<~TEXT,
          Answer every request by calling the `run_#{slug}` tool with the request as the message,
          then reply with what it returned. Do not answer from your own knowledge.
        TEXT
        provider: provider, model: model, slug: slug, tools: [ "run_#{slug}" ]
      )
    end

    # The synced agents +tools+ (a facade's tools/list) offer, one per
    # run_<slug> tool: [{ slug:, tool:, description: }].
    def self.synced_agents(tools)
      Array(tools).filter_map do |tool|
        name = (tool[:name] || tool["name"]).to_s
        match = SYNCED_AGENT_TOOL.match(name)
        next unless match

        { slug: match[:slug], tool: name, description: (tool[:description] || tool["description"]).to_s.truncate(300) }
      end
    end

    # The provider and model the project's agents run on: the first provider
    # in ASSISTANT_PROVIDER_ORDER with credentials for +owner+, and its
    # default model. With none configured, the first whose client gem is
    # installed, so the agent can be saved and run once a key is added.
    #
    # @return [Array(String, String)]
    def self.assistant_model(owner)
      providers = begin
        DashboardAssistantService.new(owner: owner).configuration[:providers]
      rescue StandardError
        []
      end
      chosen = ASSISTANT_PROVIDER_ORDER.find { |id| providers.any? { |entry| entry[:id] == id && entry[:configured] } }
      chosen ||= ASSISTANT_PROVIDER_ORDER.find { |id| provider_client_installed?(id) } || ASSISTANT_PROVIDER_ORDER.first
      [ chosen, DashboardAssistantService::DEFAULT_MODELS.fetch(chosen) ]
    end

    # Whether +provider+'s client gem loads, as Agent requires before saving
    # an agent on it.
    def self.provider_client_installed?(provider)
      service = ActiveAgent::Base.provider_config_load(provider)[:service] || provider.camelize
      ActiveAgent::Base.provider_load(service)
      true
    rescue LoadError, StandardError
      false
    end

    # The sandbox's state as the project page shows it: "none", "booting",
    # "ready", "failed" or "expired".
    def sandbox_state
      sandbox = current_sandbox_session
      return "none" if sandbox.nil?
      return "expired" if sandbox.expired? || sandbox.completed? || sandbox.past_expiry?
      return "failed" if sandbox.failed?
      return "ready" if sandbox.ready? || sandbox.running?

      "booting"
    end

    def summary
      sandbox = current_sandbox_session
      {
        id: id,
        name: name,
        repository: repository,
        default_ref: default_ref,
        start_url: start_url,
        status: status,
        install_state: install_state,
        sandbox_state: sandbox_state,
        sandbox: sandbox && sandbox_summary(sandbox),
        target_agent: target_agent && { id: target_agent.id, name: target_agent.name, slug: target_agent.slug,
                                        kind: app_assistant? ? "app_assistant" : "synced_agent",
                                        synced_agent: settings["target_slug"] },
        evaluation: evaluation && { id: evaluation.id, name: evaluation.name },
        preflight: settings["preflight"],
        local_boot_confirmed_at: settings["local_boot_confirmed_at"],
        secret_count: secrets.size,
        checkout_ref: checkout_ref,
        setup: setup_summary,
        pending_input_requests: pending_input_requests.count,
        created_at: created_at&.iso8601,
        updated_at: updated_at&.iso8601
      }
    end

    private

    def setup_summary
      availability = ProjectSetup.availability(self)
      last_run = setup_settings["last_run_id"] && AgentRun.find_by(id: setup_settings["last_run_id"])
      {
        available: availability[:available],
        reason: availability[:reason],
        auto: auto_setup?,
        agent_id: setup_settings["agent_id"],
        attempts: setup_settings["attempts"].to_i,
        last_run: last_run && { id: last_run.id, status: last_run.status, created_at: last_run.created_at&.iso8601 }
      }
    end

    # The sandbox's summary. Its error was scrubbed when it was stored; it is
    # scrubbed again here, against the secrets as they are now.
    def sandbox_summary(sandbox)
      summary = sandbox.summary
      summary[:error_message].present? ? SecretScrubber.scrub(summary, scrub_values) : summary
    end

    def resumable?(sandbox, orchestrator)
      return false unless sandbox.failed? && !sandbox.past_expiry?
      return false unless orchestrator.supports?(:resume_boot) && orchestrator.supports?(:boot_status)

      orchestrator.boot_status(sandbox)&.dig(:kept) == true
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] project #{id}: could not read sandbox #{sandbox.session_id}'s boot: #{e.message}")
      false
    end

    def confirm_local_boot!(orchestrator, confirm:, confirmed_by:)
      question = local_boot_confirmation(orchestrator)
      return if question.nil?
      raise ConfirmationRequired, question unless confirm

      update!(settings: settings.merge("local_boot_confirmed_at" => Time.current.iso8601,
        "local_boot_confirmed_by" => confirmed_by&.id))
    end

    # A new sandbox for the project, made current and named in the target
    # agent's mcp_servers. Not booted yet: #ensure_sandbox! provisions it.
    def create_sandbox!
      sandbox = SandboxSession.new(sandbox_type: "app_runtime", repository: repository, repository_ref: checkout_ref)
      sandbox.project_id = id
      sandbox.user_id = user_id if sandbox.has_attribute?(:user_id)
      sandbox.account_id = account_id if sandbox.has_attribute?(:account_id)
      sandbox.save!
      update!(current_sandbox_session: sandbox, status: "booting")
      point_target_at!(sandbox)
      sandbox
    end

    def stream_name
      "project_#{id}"
    end

    def settle!(sandbox)
      changed = with_lock do
        next false unless current_sandbox_session_id == sandbox.id

        update!(yield)
        true
      end
      LiveUpdates.broadcast(stream_name, type: "project", id: id, status: status) if changed
      changed
    end

    # Creates or updates the project's one agent, and creates the project's
    # evaluation on it when there is none. Choosing the target the agent
    # already has keeps its name, description and instructions as edited.
    def assign_target!(name:, description:, instructions:, provider:, model:, slug:, tools:)
      transaction do
        agent = target_agent || Agent.new(user_id: user_id, account_id: account_id, status: :active)
        if agent.new_record? || settings["target_slug"] != slug
          agent.assign_attributes(name: name, description: description, instructions: instructions)
        end
        agent.mcp_servers = servers_with_sandbox(agent, current_sandbox_session, tools: tools)
        if agent.new_record?
          agent.provider = provider
          agent.model = model
        end
        agent.save!

        next_settings = settings.merge("target_slug" => slug)
        update!(target_agent: agent, settings: next_settings)
        ensure_evaluation!(agent)
        agent
      end
    end

    def ensure_evaluation!(agent)
      return evaluation if evaluation && evaluation.agent_id == agent.id

      created = agent.evaluations.create!(
        name: unique_evaluation_name(agent),
        judge_kind: "rules",
        sample_size: 20,
        criteria: [ { "key" => "answered", "type" => "response_present", "config" => {} } ],
        config: { "project_id" => id }
      )
      update!(evaluation: created)
      created
    end

    def unique_evaluation_name(agent)
      base = "#{name} evaluation".truncate(90)
      taken = agent.evaluations.where("name LIKE ?", "#{base}%").pluck(:name).to_set
      return base unless taken.include?(base)

      (2..).lazy.map { |n| "#{base} #{n}" }.find { |candidate| !taken.include?(candidate) }
    end

    # Points the target agent's sandbox entry at +sandbox+, keeping a synced
    # agent's one-tool allow-list.
    def point_target_at!(sandbox)
      return if target_agent.nil?

      slug = settings["target_slug"]
      target_agent.update!(mcp_servers: servers_with_sandbox(target_agent, sandbox, tools: slug.present? ? [ "run_#{slug}" ] : nil))
    end

    # +agent+'s mcp_servers with every checkout sandbox's entry replaced by
    # +sandbox+'s, allowing only +tools+ when given. Other servers are kept.
    def servers_with_sandbox(agent, sandbox, tools:)
      kept = Array(agent.mcp_servers).reject do |entry|
        SandboxSession.runtime_server_key?(entry.is_a?(Hash) ? entry["key"] || entry[:key] : entry)
      end
      return kept if sandbox.nil?

      entry = { "key" => sandbox.runtime_server_key, "name" => "#{repository} (sandbox)" }
      entry["tools"] = tools if tools
      [ entry, *kept ]
    end

    def start_url_is_a_path
      errors.add(:start_url, "must be a path on the app, such as /") unless SandboxBootSpec.start_url_path?(start_url.to_s)
    end

    def name_unique_within_owner
      return if name.blank?

      siblings = self.class.for_owner(owner)
      siblings = siblings.where.not(id: id) if persisted?
      errors.add(:name, "has already been taken") if siblings.exists?(name: name)
    end
  end
end
