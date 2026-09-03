require "bundler/setup"
require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb", "actionagent/test/**/*_test.rb"]
    .exclude("test/**/integration_test.rb")
    .exclude("test/dummy/tmp/**/*")
  t.verbose = true
end

task default: :test

# Every gem in the repo, built into pkg/. bundler/gem_tasks only discovers the
# gemspec at the repository root, so `rake build` alone would silently ship
# the framework and never the dashboard.
#
# Each is built from its own directory, which is not a stylistic choice:
# RubyGems resolves a gemspec's file list against the working directory, so
# `gem build actionagent/actionagent.gemspec` from here reads the wrong tree.
#
# Mirrors activeagents-telemetry's build_all, which packages its adapters the
# same way.
task :build_all do
  require "fileutils"
  root = Dir.pwd
  FileUtils.mkdir_p("pkg")

  # A gem that installs and resolves but dies on require is the failure this
  # guards against, and it is invisible without looking inside the archive.
  required_contents = {
    "activeagent" => %w[lib/active_agent.rb],
    "actionagent" => %w[
      lib/action_agent.rb
      config/routes.rb
      app/assets/builds/action_agent.js
      app/assets/builds/action_agent.css
    ]
  }

  Dir["*.gemspec", "actionagent/*.gemspec"].each do |spec|
    Dir.chdir(File.dirname(spec)) do
      sh "gem build #{File.basename(spec)}"

      Dir["*.gem"].each do |gem_file|
        name = gem_file[/\A(.+)-\d/, 1]
        contents = `tar -xOf #{gem_file} data.tar.gz | tar -tzf -`

        required_contents.fetch(name, []).each do |path|
          raise "#{gem_file} is missing #{path}" unless contents.include?("#{path}\n")
        end

        FileUtils.mv(gem_file, File.join(root, "pkg", gem_file))
      end
    end
  end

  puts "\nBuilt:"
  Dir["pkg/*.gem"].sort.each { |gem_file| puts "  #{gem_file}" }
  puts "\nPublish activeagent before actionagent, which depends on it."
end
