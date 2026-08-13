require_relative "lib/action_agent/version"

Gem::Specification.new do |spec|
  spec.name = "actionagent"
  spec.version = ActionAgent::VERSION
  spec.summary = "The Active Agent dashboard, as a mountable Rails engine"
  spec.description = "Mount a dashboard for your agents in any Rails app: build and run agents, " \
    "read their conversations, score them with evaluations, and watch traces, metrics and costs — " \
    "served from your own database, on your own domain."
  spec.authors = [ "Justin Bowen" ]
  spec.email = "jusbowen@gmail.com"

  # The React sources under frontend/ build into app/assets/builds, which is
  # what ships. Host apps never run a JavaScript build, so the sources (and
  # their node_modules) stay out of the gem.
  spec.files = Dir[
    "app/**/*",
    "config/**/*",
    "lib/**/*",
    "README.md",
    "LICENSE"
  ]
  spec.require_paths = "lib"
  spec.homepage = "https://activeagents.ai"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata = {
    "bug_tracker_uri" => "https://github.com/activeagents/activeagent/issues",
    "documentation_uri" => "https://docs.activeagents.ai/framework/self-hosted-observability",
    "source_code_uri" => "https://github.com/activeagents/activeagent",
    "rubygems_mfa_required" => "true"
  }

  # The dashboard executes agents through the framework.
  spec.add_dependency "activeagent", ">= 1.1", "< 2"

  # It is a Rails engine with Active Record models, so unlike the framework it
  # genuinely needs both. Keeping these here is the point of the separate gem:
  # `activeagent` can stay usable in an app that has neither.
  spec.add_dependency "railties", ">= 7.2", "<= 9.0"
  spec.add_dependency "activerecord", ">= 7.2", "<= 9.0"

  # Conversation persistence. AgentExecutionService mixes SolidAgent::HasContext
  # into the class it builds for a run, so this is a hard requirement — and one
  # `activeagent` could never declare, since solid_agent depends on it.
  spec.add_dependency "solid_agent", ">= 0.1"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "sqlite3"
end
