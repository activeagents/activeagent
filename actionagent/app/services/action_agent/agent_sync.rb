# frozen_string_literal: true

module ActionAgent
  # Mirrors host ActiveAgent classes into Agent records, so the dashboard can
  # run, evaluate and release the agents an app already has in code.
  #
  # The engine reads an agent's identity from the class rather than asking the
  # host to restate it: name, description and tool roster all come from the
  # class, and re-running the sync updates each record in place. `AgentRelease`
  # already expects `agent_class_name` to be set by "whatever syncs its
  # ActiveAgent classes into Agent records" — this is that, so a host no longer
  # has to write it.
  #
  # The split is deliberate and is the reason this is safe to run on deploy:
  #
  # * **The code owns what an agent is** — name, description, instructions,
  #   tools. Rewritten on every sync, so it cannot drift from the class.
  # * **The operator owns how it runs** — provider, model, status. Set once on
  #   create and never touched again, so a model chosen in the dashboard
  #   survives the next deploy.
  #
  #   ActionAgent::AgentSync.call(RecordAgent.all, owner: owner)
  #
  # @see AgentRelease which cuts a version per synced agent
  class AgentSync
    Row = Struct.new(:agent, :created, :skipped, keyword_init: true)
    Result = Struct.new(:rows, :errors, keyword_init: true) do
      def success? = errors.blank?
      def agents = rows.filter_map(&:agent)
      def created = rows.select(&:created)
      def skipped = rows.select(&:skipped)
    end

    # @param agents [Array<Class>] ActiveAgent::Base subclasses
    # @param owner [Object] the record agents and API keys scope to
    # @param provider [String, Symbol, nil] defaults to the class's own
    # @param model [String, nil] defaults to the class's own
    def self.call(agents, owner:, provider: nil, model: nil)
      new(agents, owner: owner, provider: provider, model: model).call
    end

    def initialize(agents, owner:, provider: nil, model: nil)
      @agents = Array(agents)
      @owner = owner
      @provider = provider
      @model = model
    end

    # @return [Result]
    def call
      return Result.new(rows: [], errors: "An owner is required: the engine scopes agents to one.") if @owner.nil?

      rows = Agent.transaction { @agents.map { |klass| upsert(klass) } }
      Result.new(rows: rows, errors: nil)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(rows: [], errors: e.record.errors.full_messages.join(", "))
    end

    private

    def upsert(klass)
      unless klass.respond_to?(:prompt_options)
        return Row.new(agent: nil, created: false, skipped: "#{klass} is not an ActiveAgent::Base subclass")
      end

      provider = resolved_provider(klass)
      model = resolved_model(klass)
      if provider.blank? || model.blank?
        return Row.new(agent: nil, created: false, skipped: "#{klass} has no provider/model configured")
      end

      # Slugs are unique per owner, so the lookup is too: unscoped, a second
      # owner's sync would find the first owner's record and rewrite it.
      agent = Agent.for_owner(@owner).find_or_initialize_by(slug: self.class.slug_for(klass))
      created = agent.new_record?
      if created
        agent.owner = @owner
        agent.provider = provider
        agent.model = model
        agent.status = :active
      end

      agent.assign_attributes(
        name: klass.name.titleize,
        agent_class_name: klass.name,
        description: description_for(klass),
        instructions: instructions_for(klass),
        tools: tool_names_for(klass)
      )
      agent.save!
      Row.new(agent: agent, created: created, skipped: nil)
    end

    # "TicketAgent" -> "ticket-agent", the slug an MCP client sees as
    # run_ticket-agent. A namespaced class flattens its separators, because
    # Agent validates slugs as /\A[a-z0-9\-_]+\z/ — "Billing::TicketAgent"
    # becomes "billing-ticket-agent".
    def self.slug_for(klass)
      klass.name.underscore.tr("/", "-").tr("_", "-")
    end

    # An agent's own description if it declares one (a delegation contract is
    # where an agent says what it answers), else its titleized name.
    def description_for(klass)
      contract = klass.try(:delegation_contracts)&.values&.first
      contract&.try(:description).presence || klass.name.titleize
    end

    # The rendered instructions, so the dashboard record runs on the same text
    # the class does rather than a hand-maintained copy.
    #
    # An agent whose instructions are assembled rather than rendered straight
    # from its own template — filled from assigns it computes, or falling back
    # to a template it shares with sibling agents — says so by defining
    # `dashboard_instructions_text`. That is asked first, because only the
    # class knows how its own prompt is built.
    def instructions_for(klass)
      return klass.dashboard_instructions_text.presence if klass.respond_to?(:dashboard_instructions_text)

      klass.try(:rendered_instructions).presence
    end

    def tool_names_for(klass)
      names = klass.try(:tool_names)
      Array(names).map(&:to_s)
    end

    def resolved_provider(klass)
      (@provider || klass.prompt_options[:service]).to_s.downcase.presence
    end

    def resolved_model(klass)
      (@model || klass.prompt_options[:model]).presence
    end
  end
end
