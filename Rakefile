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

# bundler/gem_tasks only discovers the gemspec at the repository root, so the
# dashboard gem needs its own build path. It must be built from its own
# directory: RubyGems resolves a gemspec's file list against the working
# directory, so `gem build actionagent/actionagent.gemspec` from here would
# not find the files it lists.
namespace :actionagent do
  desc "Build the actionagent gem into pkg/"
  task :build do
    require "fileutils"
    root = File.expand_path(__dir__)
    FileUtils.mkdir_p(File.join(root, "pkg"))

    Dir.chdir(File.join(root, "actionagent")) do
      sh "gem build actionagent.gemspec"
      version = File.read("lib/action_agent/version.rb")[/VERSION = "([^"]+)"/, 1]
      gem_file = "actionagent-#{version}.gem"

      # A gem missing its own entry point is the failure mode this guards
      # against — it installs and resolves, then dies on require.
      contents = `tar -xOf #{gem_file} data.tar.gz | tar -tzf -`
      %w[lib/action_agent.rb config/routes.rb app/assets/builds/action_agent.js].each do |required|
        raise "actionagent gem is missing #{required}" unless contents.include?(required)
      end

      FileUtils.mv(gem_file, File.join(root, "pkg", gem_file))
      puts "actionagent #{version} -> pkg/#{gem_file}"
    end
  end
end
