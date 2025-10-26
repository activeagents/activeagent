require "test_helper"
require "generators/active_agent/install/install_generator"

class ActiveAgent::Generators::InstallGeneratorTest < Rails::Generators::TestCase
  tests ActiveAgent::Generators::InstallGenerator
  destination Rails.root.join("tmp/generators")
  setup :prepare_destination

  test "creates configuration file" do
    run_generator

    assert_file "config/active_agent.yml"
  end

  test "creates application agent" do
    run_generator

    assert_file "app/agents/application_agent.rb" do |content|
      assert_match(/class ApplicationAgent < ActiveAgent::Base/, content)
      assert_match(/generate_with :openai/, content)
    end
  end

  test "does not overwrite existing application agent" do
    FileUtils.mkdir_p(File.join(destination_root, "app/agents"))
    File.write(File.join(destination_root, "app/agents/application_agent.rb"), "# existing content")

    run_generator

    assert_file "app/agents/application_agent.rb" do |content|
      assert_match(/# existing content/, content)
      assert_no_match(/class ApplicationAgent < ActiveAgent::Base/, content)
    end
  end

  test "works with default options" do
    run_generator

    assert_file "config/active_agent.yml"
    assert_file "app/agents/application_agent.rb"
  end

  test "skips configuration file when skip_config option is provided" do
    run_generator [ "--skip-config" ]

    assert_no_file "config/active_agent.yml"
    assert_file "app/agents/application_agent.rb"
  end

  test "creates configuration file by default" do
    run_generator

    assert_file "config/active_agent.yml"
    assert_file "app/agents/application_agent.rb"
  end

  test "skip_config option does not affect other files" do
    run_generator [ "--skip-config" ]

    assert_no_file "config/active_agent.yml"
    assert_file "app/agents/application_agent.rb"
  end
end
