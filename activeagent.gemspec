require_relative "lib/active_agent/version"

Gem::Specification.new do |spec|
  spec.name = "activeagent"
  spec.version = ActiveAgent::VERSION
  spec.summary = "Rails AI Agents Framework"
  spec.description = "The only agent-oriented AI framework designed for Rails, where Agents are Controllers. Build AI features with less complexity using the MVC conventions you love."
  spec.authors = [ "Justin Bowen" ]
  spec.email = "jusbowen@gmail.com"
  spec.files = Dir["CHANGELOG.md", "README.md", "LICENSE", "lib/**/*"]
  spec.require_paths = "lib"
  spec.homepage = "https://activeagents.ai"
  spec.license = "MIT"

  spec.metadata = {
    "bug_tracker_uri" => "https://github.com/activeagents/activeagent/issues",
    "documentation_uri" => "https://github.com/activeagents/activeagent",
    "source_code_uri" => "https://github.com/activeagents/activeagent",
    "rubygems_mfa_required" => "true"
  }
  # Add dependencies
  spec.add_dependency "actionpack", ">= 7.2", "< 9.0"
  spec.add_dependency "actionview", ">= 7.2", "< 9.0"
  spec.add_dependency "activesupport", ">= 7.2", "< 9.0"
  spec.add_dependency "activemodel", ">= 7.2", "< 9.0"
  spec.add_dependency "activejob", ">= 7.2", "< 9.0"

  spec.add_development_dependency "jbuilder"
  spec.add_development_dependency "rails"
end
