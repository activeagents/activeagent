# Helpers for rehearsing the talk. None of them is needed to run the app.
namespace :snag do
  desc "Put the tracker's people, issues and comments back to the seeded backlog (dashboard data is kept)"
  task reset: :environment do
    [ Comment, Issue, User ].each(&:delete_all)
    %w[comments issues users].each do |table|
      ActiveRecord::Base.connection.execute("DELETE FROM sqlite_sequence WHERE name = '#{table}'")
    end
    Rails.application.load_seed
  end

  desc "Create the Issue Agent as the talk builds it by hand: read-only. WRITES=1 also grants the tools that change issues"
  task agent: :environment do
    reads  = IssueTools.tool_names + UserTools.tool_names + %w[find_comments]
    writes = %w[create_issue update_issue add_comment]

    agent = ActionAgent::Agent.find_or_initialize_by(slug: Assistant::SLUG)
    agent.update!(
      name: "Issue Agent",
      description: "Answers questions about the Snag backlog and, when allowed, triages it.",
      provider: "anthropic",
      model: ActiveAgent.configuration[:anthropic][:model],
      status: :active,
      instructions: Rails.root.join("docs/issue_agent_instructions.md").read,
      tools: ENV["WRITES"] ? reads + writes : reads
    )
    puts "#{agent.name} (#{agent.slug}) on #{agent.provider}/#{agent.model} with #{agent.tools.size} tools."
  end

  namespace :evals do
    desc "Turn what people asked the agent into an evaluation suite: one scenario per user message"
    task from_conversations: :environment do
      agent = Assistant.agent or abort "No agent yet. Build one in the dashboard, or run bin/rails snag:agent."
      scenarios = ConversationScenarios.new(agent).call
      abort "Nobody has talked to #{agent.name} yet." if scenarios.empty?

      evaluation = ActionAgent::Evaluation.find_or_create_by!(agent: agent, name: ENV.fetch("NAME", "Real conversations")) do |record|
        record.judge_kind = "llm"
        record.sample_size = 20
        record.criteria = [ { "key" => "response_present", "type" => "response_present", "config" => {} } ]
      end
      merged = evaluation.merge_scenarios!(scenarios)

      puts "#{evaluation.name}: #{merged[:added].size} added, #{merged[:updated].size} updated, " \
           "#{merged[:unchanged].size} unchanged (#{evaluation.scenarios.count} scenarios)."
      puts "Open /activeagents/evaluations and press Run."
    end
  end
end

namespace :snag do
  desc "Forget everything the dashboard recorded: agents, conversations, traces, evaluations"
  task forget: :environment do
    connection = ActiveRecord::Base.connection
    connection.disable_referential_integrity do
      connection.tables.grep(/\Aactive_agent_/).each { |table| connection.execute("DELETE FROM #{connection.quote_table_name(table)}") }
    end
    puts "Dashboard data cleared."
  end
end
