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
    "documentation_uri" => "https://docs.activeagents.ai",
    "source_code_uri" => "https://github.com/activeagents/activeagent",
    "rubygems_mfa_required" => "true"
  }
  # Add dependencies
  spec.add_dependency "actionpack", ">= 7.2", "<= 9.0"
  spec.add_dependency "actionview", ">= 7.2", "<= 9.0"
  spec.add_dependency "activesupport", ">= 7.2", "<= 9.0"
  spec.add_dependency "activemodel", ">= 7.2", "<= 9.0"
  spec.add_dependency "activejob", ">= 7.2", "<= 9.0"

  spec.add_development_dependency "jbuilder", "~> 2.14"

  spec.add_development_dependency "anthropic", "~> 1.12"
  spec.add_development_dependency "aws-sdk-bedrockruntime"
  spec.add_development_dependency "openai", "~> 0.34"
  spec.add_development_dependency "ruby_llm", ">= 1.0"

  spec.add_development_dependency "capybara", "~> 3.40"
  spec.add_development_dependency "cuprite", "~> 0.15"
  spec.add_development_dependency "ostruct"
  spec.add_development_dependency "puma"
  spec.add_development_dependency "sqlite3"
  spec.add_development_dependency "minitest", "~> 5.0"
  # Older vcr 6.3.x breaks on Ruby 3.5+/4.0 with a CGI.parse NameError. Keep a
  # floor so no gemfile resolves back to the broken version.
  spec.add_development_dependency "vcr", ">= 6.4"
  spec.add_development_dependency "webmock", ">= 3.26"
  # vcr calls CGI.parse but doesn't declare `cgi` itself. Depend on it directly
  # so it's installed on Ruby 3.5+/4.0 where `cgi` is no longer a default gem.
  spec.add_development_dependency "cgi"

  # dotenv >= 3.2 avoids the activation conflict older 3.1.x hits under Ruby 4.0.
  spec.add_development_dependency "dotenv", ">= 3.2"
  spec.add_development_dependency "pry"
  spec.add_development_dependency "pry-byebug"
  spec.add_development_dependency "pry-doc"
end
