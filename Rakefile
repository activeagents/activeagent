require "bundler/setup"
require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
    .exclude("test/**/integration_test.rb")
    .exclude("test/dummy/tmp/**/*")
  t.verbose = true
end

task default: :test
