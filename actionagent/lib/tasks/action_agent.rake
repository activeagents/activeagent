# frozen_string_literal: true

namespace :action_agent do
  desc "Seed the dashboard's default agent templates (idempotent — existing slugs are kept)"
  task seed_templates: :environment do
    ActionAgent::AgentTemplate.seed_defaults!
    puts "Agent template library: #{ActionAgent::AgentTemplate.count} templates"
  end

  # Sample data a workspace can show before it has run anything of its own.
  # On a multi-tenant install name the workspace: ACCOUNT_ID=<id> (or
  # USER_ID=<id> where agents belong to users).
  namespace :sample do
    desc "Seed the conference-ticket sample: an agent, a week of runs and traces, a replayable handoff, and an evaluation history"
    task conference_ticket: :environment do
      ActionAgent::AgentTemplate.seed_defaults!
      agent = ActionAgent::SampleData::ConferenceTicket.seed!(owner: action_agent_sample_owner)
      traces = ActionAgent.trace_model.where(agent_id: agent.id).count
      evaluation = agent.evaluations.find_by(name: ActionAgent::SampleData::ConferenceTicket::EVALUATION_NAME)
      puts "Conference ticket sample: agent ##{agent.id} (#{agent.slug})"
      puts "  #{agent.agent_runs.count} runs, #{traces} traces, " \
           "#{ActionAgent::SessionRecording.where(agent_run_id: agent.agent_runs.select(:id)).count} session recording"
      puts "  evaluation \"#{evaluation&.name}\": #{evaluation&.evaluation_runs&.count} runs over #{evaluation&.scenarios&.count} scenarios"
    end

    desc "Remove the conference-ticket sample and everything it created"
    task clear: :environment do
      removed = ActionAgent::SampleData::ConferenceTicket.clear!(owner: action_agent_sample_owner)
      puts removed.zero? ? "No conference ticket sample to remove" : "Conference ticket sample removed"
    end
  end
end

# The workspace the sample belongs to, from ACCOUNT_ID or USER_ID; nil on a
# single-user install.
def action_agent_sample_owner
  if ENV["ACCOUNT_ID"].present?
    ActionAgent.account_class.to_s.constantize.find(ENV["ACCOUNT_ID"])
  elsif ENV["USER_ID"].present?
    ActionAgent.user_class.to_s.constantize.find(ENV["USER_ID"])
  end
end

namespace :action_agent do
  namespace :agents do
    desc "Cut a dashboard version for every agent whose code changed (run on deploy; REVISION=<git sha> to label it)"
    task :release, [ :revision ] => :environment do |_task, args|
      Rails.application.eager_load!
      result = ActionAgent::AgentRelease.call(revision: args[:revision] || ENV["REVISION"], released_by: ENV["RELEASED_BY"])

      puts "Release #{result.revision.presence || '(no revision)'}"
      result.rows.each do |row|
        if row.skipped
          puts format("  %-28s skipped — %s", row.agent.name, row.skipped)
        elsif row.cut
          puts format("  %-28s v%-3d cut   %s", row.agent.name, row.version.version_number, row.version.change_summary)
        else
          puts format("  %-28s v%-3d unchanged (%s)", row.agent.name, row.version.version_number, row.version.release_digest)
        end
      end
      puts "#{result.cut.size} cut, #{result.rows.size - result.cut.size - result.skipped.size} unchanged, #{result.skipped.size} skipped"
    end

    desc "List each agent's current version and release"
    task versions: :environment do
      ActionAgent::Agent.order(:name).find_each do |agent|
        version = agent.latest_version
        release = agent.latest_release
        puts format("%-28s v%-3s %s%s", agent.name, version&.version_number || "-",
                    release ? "release #{release.release_digest}" : "no release",
                    release&.revision.present? ? " · #{release.revision}" : "")
      end
    end
  end
end
