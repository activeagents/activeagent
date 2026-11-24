# The tracker's side of the agent: which dashboard agent the chat panel talks
# to, and the conversation it keeps per browser session.
#
# The agent itself is not defined in this app's code. It is a record built in
# the dashboard (/activeagents), with the tools from app/agent_tools switched
# on there. The panel appears once such an agent exists.
class Assistant
  SLUG = ENV.fetch("SNAG_AGENT", "issue-agent")
  ISSUE_TOOLS = %w[find_issues search_issues get_issue].freeze

  Turn = Struct.new(:role, :content, :tools, keyword_init: true)

  class << self
    # The agent named SNAG_AGENT (default "issue-agent", what the dashboard
    # calls an agent named "Issue Agent"), else the newest agent that was
    # given a tool for reading issues.
    def agent
      runnable = ActionAgent::Agent.where(status: %i[draft active])
      runnable.find_by(slug: SLUG) ||
        runnable.order(updated_at: :desc).detect { |agent| (Array(agent.tools) & ISSUE_TOOLS).any? }
    end

    # The session's conversation with the agent, started on first use. Runs
    # pinned to it are sent its earlier turns, so "assign that one to Sofia"
    # means what it would mean to a person.
    def conversation(agent, session)
      action = ActionAgent::Agent::DEFAULT_ACTION
      ActionAgent::AgentContext.find_by(id: session[:assistant_context_id], contextable: agent, action_name: action) ||
        ActionAgent::AgentContext.create!(
          contextable: agent,
          agent_name: agent.telemetry_agent_class,
          action_name: action,
          instructions: agent.composed_instructions_for(action)
        ).tap { |context| session[:assistant_context_id] = context.id }
    end

    def turns(agent, session)
      context = ActionAgent::AgentContext.find_by(id: session[:assistant_context_id], contextable: agent)
      return [] unless context

      tools = []
      context.messages.chronological.where(role: %w[user assistant tool]).filter_map do |message|
        if message.role == "tool"
          tools << message.tool_name
          next
        end
        next if message.content.blank?

        Turn.new(role: message.role, content: message.content, tools: tools.compact.uniq).tap { tools = [] }
      end
    end
  end
end
