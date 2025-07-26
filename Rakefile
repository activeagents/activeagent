require "bundler/setup"
require "bundler/gem_tasks"

desc "Run tests"
task :test do
  $: << File.expand_path("test", __dir__)
  require "rails/plugin/test"
end
