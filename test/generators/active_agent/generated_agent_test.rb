require "test_helper"
require "generators/active_agent/agent/agent_generator"
require "open3"

class ActiveAgent::Generators::GeneratedAgentTest < Rails::Generators::TestCase
  tests ActiveAgent::Generators::AgentGenerator
  destination Rails.root.join("tmp/generated_agent_tests")
  setup :prepare_destination

  test "generated agent tests run in a Rails host" do
    assert_generated_tests_run "generated_example", 2
  end

  test "generated namespaced agent tests run in a Rails host" do
    assert_generated_tests_run "admin/generated_example", 2
  end

  test "generated agent tests without actions load in a Rails host" do
    assert_generated_tests_run "generated_example", 0, actions: []
  end

  private

  def assert_generated_tests_run(name, count, actions: %w[create update])
    run_generator [ name, *actions, "--test-framework=test_unit" ]
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(File.join(destination_root, "config/routes.rb"), "Rails.application.routes.draw {}\n")
    File.write(File.join(destination_root, "test/test_helper.rb"), <<~RUBY)
      ENV["RAILS_ENV"] = "test"
      require "rails"
      require "active_model/railtie"
      require "active_job/railtie"
      require "action_controller/railtie"
      require "active_agent"
      class GeneratedHost < Rails::Application
        config.root = File.expand_path("..", __dir__)
        config.eager_load = false
        config.secret_key_base = "synthetic-test-secret"
        config.logger = Logger.new(File::NULL)
      end
      GeneratedHost.initialize!
      require "rails/test_help"
    RUBY

    output, status = Open3.capture2e(
      RbConfig.ruby, "-Itest", "test/agents/#{name}_agent_test.rb",
      chdir: destination_root
    )
    assert status.success?, output
    assert_match(/#{count} runs, #{count} assertions, 0 failures, 0 errors/, output)
  end
end
