# frozen_string_literal: true

module ActionAgent
  # Registers an Agent for each distinct agent action we observe in telemetry.
  #
  # Agents authored in the dashboard have records; agents running inside a
  # customer's own app only ever reported traces, so the Agents list read 0 while
  # Traces and Interactions were full of their runs. Ingest calls this to give
  # every observed agent an identity that evaluations, versions, and per-agent
  # metrics can hang off.
  #
  # Identity is (account, service_name, agent_class, agent_action) — one agent
  # per action, not per class. Assistant.respond (admin assistant, every MCP
  # tool, ~$0.03/run) and Assistant.title (no tools, temperature 0.2,
  # ~$0.0004/run) are different agents that share a class name because one app
  # method spawns both.
  # Collapsing them would blend a $0.03 agent with a $0.0004 one into a single
  # meaningless cost-per-run.
  #
  # Never raises: a registration failure must not fail a customer's telemetry.
  class AgentRegistrar
    # Guards against a misconfigured reporter with a dynamic agent class
    # creating unbounded records.
    MAX_OBSERVED_PER_OWNER = 200

    def self.call(trace)
      new(trace).call
    rescue StandardError => e
      Rails.logger.warn("[AgentRegistrar] #{e.class}: #{e.message}")
      nil
    end

    def initialize(trace)
      @trace = trace
    end

    def call
      return if @trace.agent_id.present?
      return if agent_class.blank?

      owner = owner_for_trace
      return if owner.nil? && ActionAgent.multi_tenant?

      agent = find_or_create_agent(owner)
      return if agent.nil?

      @trace.update_columns(agent_id: agent.id)
      touch_observation(agent)
      agent
    end

    private

    attr_reader :trace

    def agent_class
      @trace.agent_class.presence
    end

    def action_name
      @trace.agent_action.presence
    end

    # Name carries the action so the two agents are distinguishable anywhere a
    # bare agent name is shown.
    def display_name
      action_name ? "#{agent_class}.#{action_name}" : agent_class
    end

    # Who the agents observed on this trace belong to. Multi-tenant installs
    # resolve the trace's tenant; a single-tenant dashboard owns everything
    # itself, so there is nothing to attribute to.
    def owner_for_trace
      resolver = ActionAgent.trace_owner_resolver
      return resolver.call(@trace) if resolver

      ActionAgent.multi_tenant? ? @trace.try(:account) : nil
    end

    def find_or_create_agent(owner)
      agents = Agent.for_owner(owner)
      existing = agents.find_by(
        service_name: @trace.service_name,
        agent_class_name: agent_class,
        action_name: action_name
      )
      return existing if existing

      return if agents.observed_agents.count >= MAX_OBSERVED_PER_OWNER

      create_observed_agent(owner)
    rescue ActiveRecord::RecordNotUnique
      # Expected when concurrent ingest registers the same agent twice: the other
      # writer won, so adopt its record. If no such record exists the collision
      # was something else (a slug clash, say) and must not be swallowed.
      agents.find_by(
        service_name: @trace.service_name,
        agent_class_name: agent_class,
        action_name: action_name
      ) || raise
    end

    def create_observed_agent(owner)
      agent = Agent.new(
        name: display_name,
        slug: observed_slug(owner),
        status: :observed,
        service_name: @trace.service_name,
        agent_class_name: agent_class,
        action_name: action_name,
        source: @trace.sdk_info&.dig("name"),
        provider: llm_attribute("llm.provider") || "openai",
        model: llm_attribute("llm.model") || "unknown",
        instructions: llm_attribute("llm.instructions").to_s,
        tools: observed_tools,
        first_observed_at: @trace.timestamp,
        last_observed_at: @trace.timestamp
      )
      agent.owner = owner
      agent.save!
      agent
    end

    # Slugs are unique per owner, but a host app may have grown a global
    # unique index instead, and two tenants observing the same agent in the
    # same service would then collide — the second silently failing to
    # register. Check globally and suffix until free; it costs one query.
    def observed_slug(_owner)
      base = [ @trace.service_name, agent_class, action_name ].compact.join("-").parameterize
      return base unless Agent.exists?(slug: base)

      5.times do
        candidate = "#{base}-#{SecureRandom.hex(3)}"
        return candidate unless Agent.exists?(slug: candidate)
      end

      "#{base}-#{SecureRandom.uuid}"
    end

    # Config we can only learn by watching: the model actually used, the
    # instructions actually sent (when content capture is on), and the tools
    # actually called — which is how Assistant.respond acquires a tool list while
    # Assistant.title correctly stays empty.
    def llm_attribute(key)
      spans.filter_map { |span| span.dig("attributes", key).presence }.first
    end

    # The roster the agent was OFFERED (ActiveAgent puts it on the prompt span
    # as prompt.input.tools), falling back to the tools actually CALLED for
    # SDKs without roster capture. A tool the agent never happens to call is
    # still part of its configuration.
    def observed_tools
      offered = begin
        JSON.parse(llm_attribute("prompt.input.tools").to_s)
      rescue JSON::ParserError
        []
      end
      names = Array(offered).filter_map { |tool| tool.is_a?(Hash) ? tool["name"].presence : nil }
      names.presence || spans.filter_map { |span| span.dig("attributes", "tool.name").presence }.uniq
    end

    def spans
      @spans ||= Array(@trace.spans)
    end

    # Config is learned progressively. An agent first seen before content
    # capture was enabled registers with no instructions; the trace that finally
    # carries them should fill that in rather than leave the record permanently
    # blank. Only fills gaps — an operator's edits are never overwritten.
    def touch_observation(agent)
      updates = {}

      if agent.last_observed_at.blank? || agent.last_observed_at < @trace.timestamp
        updates[:last_observed_at] = @trace.timestamp
      end

      if agent.instructions.blank? && (instructions = llm_attribute("llm.instructions")).present?
        updates[:instructions] = instructions
      end

      # Union, not gap-fill: later traces legitimately grow the roster (new
      # tools ship). Names are only ever added, so operator edits survive.
      if observed_tools.any?
        merged = Array(agent.tools) | observed_tools
        updates[:tools] = merged if merged != Array(agent.tools)
      end

      if agent.model.blank? || agent.model == "unknown"
        model = llm_attribute("llm.model")
        updates[:model] = model if model.present?
      end

      return if updates.empty?

      agent.update_columns(updates.merge(updated_at: Time.current))
    end
  end
end
