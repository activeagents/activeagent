require_relative "lib/active_agent/version"

Gem::Specification.new do |spec|
  spec.name = "activeagent"
  spec.version = ActiveAgent::VERSION
  spec.summary = "Rails AI Agents Framework"
  spec.description = "A simple way to perform long running LLM background jobs and streaming responses"
  spec.authors = ["Justin Bowen"]
  spec.email = "jusbowen@gmail.com"
  # s.files = Dir["CHANGELOG.md", "README.rdoc", "MIT-LICENSE", "lib/**/*"]
  spec.require_path = "lib"
  spec.homepage = "https://rubygems.org/gems/activeagent"
  spec.license = "MIT"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end
  # Add dependencies
  spec.add_dependency "actionpack", "~> 7.2"
  spec.add_dependency "actionview", "~> 7.2"
  spec.add_dependency "activesupport", "~> 7.2"
  spec.add_dependency "activemodel", "~> 7.2"
  spec.add_dependency "activejob", "~> 7.2"

  spec.add_dependency "rails", "~> 7.2"
end
