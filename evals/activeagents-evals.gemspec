# frozen_string_literal: true

require_relative "lib/activeagents/evals/version"

Gem::Specification.new do |spec|
  spec.name = "activeagents-evals"
  spec.version = ActiveAgents::Evals::VERSION
  spec.summary = "Scenario evaluations for AI agents: replay tasks across models, diagnose faults, recommend fixes"
  spec.description = <<~DESC
    A framework-agnostic evaluation core for agents that answer with tools. Paste a list of user
    messages (or load a YAML suite), replay each one through your agent under one or more models
    via a callable you supply, score the answers against rule criteria and per-scenario
    expectations, assign every shortfall one fault with a recommendation, and roll the results up
    into a per-model summary, a verdict, and a Markdown or JSON report. Works with any agent
    stack — ActiveAgent, RubyLLM, or a plain HTTP client — and powers the ActionAgent dashboard's
    scenario evaluations.
  DESC
  spec.authors = [ "Justin Bowen" ]
  spec.email = "jusbowen@gmail.com"

  # Globbed relative to this file so `gem build` from the repository root does
  # not sweep up the framework's lib/.
  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*", "README.md", "LICENSE"]
  end
  spec.require_paths = "lib"
  spec.homepage = "https://activeagents.ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata = {
    "bug_tracker_uri" => "https://github.com/activeagents/activeagent/issues",
    "documentation_uri" => "https://docs.activeagents.ai/framework/evaluations",
    "source_code_uri" => "https://github.com/activeagents/activeagent/tree/main/evals",
    "rubygems_mfa_required" => "true"
  }

  # Only for the core extensions (presence, truncate, parameterize, deep_stringify_keys);
  # no Rails framework is loaded.
  spec.add_dependency "activesupport", ">= 7.0", "<= 9.0"

  spec.add_development_dependency "minitest", "~> 5.0"
end
