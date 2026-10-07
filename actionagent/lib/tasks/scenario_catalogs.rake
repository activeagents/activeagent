# frozen_string_literal: true

# Scenario catalogs from the command line, for a repository that keeps its
# scenarios in YAML. On a multi-tenant install name the workspace with
# ACCOUNT_ID=<id> (or USER_ID=<id> where catalogs belong to users).
#
#   bin/rails action_agent:catalogs:import FILE=config/evals/support.yml
#   bin/rails action_agent:catalogs:export KEY=support FILE=tmp/support.yml
#   bin/rails action_agent:catalogs:run KEY=support PRODUCT=triage SET=smoke [AGENT_ID=1 | PROJECT_ID=2]
namespace :action_agent do
  namespace :catalogs do
    desc "Import a scenario catalog from a YAML file (FILE=path); re-importing the same file changes nothing"
    task import: :environment do
      path = ENV.fetch("FILE") { abort "Name the file: FILE=config/evals/support.yml" }
      abort "No file at #{path}" unless File.file?(path)

      owner = action_agent_catalog_owner
      catalog = ActionAgent::ScenarioCatalogImport.new(
        owner: owner, document: File.read(path), name: File.basename(path, File.extname(path)),
        source_kind: "upload", source_path: path,
        agents: ActionAgent.agents_for(owner), projects: ActionAgent::Project.for_owner(owner)
      ).call
      puts "Catalog #{catalog.key}: #{catalog.products.count} products, #{catalog.scenario_count} scenarios" \
           "#{catalog.synced? ? ', synced to Active Storage' : ''}"
    rescue ActionAgent::ScenarioCatalogImport::Invalid => e
      abort "Import refused: #{e.message}"
    end

    desc "Write a catalog's canonical YAML (KEY=catalog key, FILE=path; standard output without FILE)"
    task export: :environment do
      catalog = action_agent_catalog!
      yaml = catalog.export_yaml
      if ENV["FILE"].present?
        File.write(ENV["FILE"], yaml)
        puts "Wrote #{catalog.key} (#{catalog.scenario_count} scenarios) to #{ENV['FILE']}"
      else
        puts yaml
      end
    end

    desc "Run one set of a catalog (KEY, PRODUCT, SET) against AGENT_ID or PROJECT_ID, or the product's own target"
    task run: :environment do
      catalog = action_agent_catalog!
      product = catalog.products.find_by!(key: ENV.fetch("PRODUCT") { abort "Name the product: PRODUCT=<key>" })
      set = product.sets.find_by!(key: ENV.fetch("SET") { abort "Name the set: SET=<key>" })
      agent = ENV["AGENT_ID"].present? ? ActionAgent::Agent.find(ENV["AGENT_ID"]) : nil
      project = ENV["PROJECT_ID"].present? ? ActionAgent::Project.find(ENV["PROJECT_ID"]) : nil

      run = set.run!(agent: agent, project: project)
      puts "Run ##{run.id} of #{set.evaluation_name} is #{run.status} (evaluation ##{run.evaluation_id})"
    rescue ActionAgent::ScenarioSet::NoAgent => e
      abort e.message
    end
  end
end

# The workspace a catalog belongs to, from ACCOUNT_ID or USER_ID; nil on a
# single-user install.
def action_agent_catalog_owner
  if ENV["ACCOUNT_ID"].present?
    ActionAgent.account_class.to_s.constantize.find(ENV["ACCOUNT_ID"])
  elsif ENV["USER_ID"].present?
    ActionAgent.user_class.to_s.constantize.find(ENV["USER_ID"])
  end
end

def action_agent_catalog!
  key = ENV.fetch("KEY") { abort "Name the catalog: KEY=<catalog key>" }
  ActionAgent::ScenarioCatalog.for_owner(action_agent_catalog_owner).find_by(key: key) ||
    abort("No catalog #{key.inspect}#{ENV['ACCOUNT_ID'].present? || ENV['USER_ID'].present? ? ' in that workspace' : ''}")
end
