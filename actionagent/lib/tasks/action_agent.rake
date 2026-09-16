# frozen_string_literal: true

namespace :action_agent do
  desc "Seed the dashboard's default agent templates (idempotent — existing slugs are kept)"
  task seed_templates: :environment do
    ActionAgent::AgentTemplate.seed_defaults!
    puts "Agent template library: #{ActionAgent::AgentTemplate.count} templates"
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
