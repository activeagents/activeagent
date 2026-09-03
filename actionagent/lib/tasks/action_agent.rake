# frozen_string_literal: true

namespace :action_agent do
  desc "Seed the dashboard's default agent templates (idempotent — existing slugs are kept)"
  task seed_templates: :environment do
    ActionAgent::AgentTemplate.seed_defaults!
    puts "Agent template library: #{ActionAgent::AgentTemplate.count} templates"
  end
end
