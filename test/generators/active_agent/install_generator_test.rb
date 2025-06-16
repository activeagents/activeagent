require "test_helper"
require "generators/active_agent/install_generator"

class ActiveAgent::Generators::InstallGeneratorTest < Rails::Generators::TestCase
  tests ActiveAgent::Generators::InstallGenerator
  destination Rails.root.join("tmp/generators")
  setup :prepare_destination

  test "creates agent layout files" do
    run_generator

    assert_file "app/views/layouts/agent.html.erb"
    assert_file "app/views/layouts/agent.text.erb"
  end

  test "creates configuration file" do
    run_generator

    assert_file "config/active_agent.yml"
  end

  test "creates application agent file" do
    run_generator

    assert_file "app/agents/application_agent.rb"
  end
end
