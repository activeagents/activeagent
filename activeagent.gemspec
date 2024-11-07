require_relative "lib/active_agent/version"

Gem::Specification.new do |s|
  s.name = "activeagent"
  s.version = ActiveAgent::VERSION::STRING
  s.summary = "Rails AI Agents Framework"
  s.description = "A simple way to perform long running LLM background jobs and streaming responses"
  s.authors = ["Justin Bowen"]
  s.email = "jusbowen@gmail.com"
  s.files = Dir["CHANGELOG.md", "README.rdoc", "MIT-LICENSE", "lib/**/*"]
  s.require_path = "lib"
  s.homepage = "https://rubygems.org/gems/activeagent"
  s.license = "MIT"

  # Add dependencies
  s.add_dependency "actionpack", "=> 7.2"
  s.add_dependency "actionview", "=> 7.2"
  s.add_dependency "activesupport", "=> 7.2"
  s.add_dependency "activemodel", "=> 7.2"
  s.add_dependency "activejob", "=> 7.2"
end
