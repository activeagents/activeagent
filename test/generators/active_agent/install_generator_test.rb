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

  test "invokes template engine generator" do
    run_generator

    assert_file "app/views/layouts/agent.html.erb"
    assert_file "app/views/layouts/agent.text.erb"
  end

  test "invokes test framework generator" do
    run_generator

    # TestUnit install generator currently doesn't create files
    # but this ensures it runs without error
    assert_file "config/active_agent.yml"
  end

  test "works with default options" do
    run_generator

    assert_file "config/active_agent.yml"
    # With default ERB template engine, layouts should be created
    assert_file "app/views/layouts/agent.html.erb"
    assert_file "app/views/layouts/agent.text.erb"
  end
end
