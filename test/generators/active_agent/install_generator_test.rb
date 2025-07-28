require "test_helper"
require "generators/active_agent/install_generator"

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
      assert_match(/layout "agent"/, content)
      assert_match(/generate_with :openai/, content)
    end
  end

  test "does not overwrite existing application agent" do
    # Create the directory first
    FileUtils.mkdir_p(File.join(destination_root, "app/agents"))
    File.write(File.join(destination_root, "app/agents/application_agent.rb"), "# existing content")

    run_generator

    assert_file "app/agents/application_agent.rb" do |content|
      assert_match(/# existing content/, content)
      assert_no_match(/class ApplicationAgent < ActiveAgent::Base/, content)
    end
  end

  test "invokes template engine generator" do
    run_generator

    assert_file "config/active_agent.yml"
    assert_file "app/agents/application_agent.rb"
    assert_file "app/views/layouts/agent.html.erb"
    assert_file "app/views/layouts/agent.text.erb"
  end

  test "invokes test framework generator" do
    run_generator

    # TestUnit install generator currently doesn't create files
    # but this ensures it runs without error
    assert_file "config/active_agent.yml"
    assert_file "app/agents/application_agent.rb"
  end

  test "works with default options" do
    run_generator

    assert_file "config/active_agent.yml"
    assert_file "app/agents/application_agent.rb"
    # With default ERB template engine, layouts should be created
    assert_file "app/views/layouts/agent.html.erb"
    assert_file "app/views/layouts/agent.text.erb"
  end
end
