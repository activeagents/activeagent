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
    assert_file "app/views/layouts/agent.text.erb"
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
    assert_file "app/views/layouts/agent.text.erb"
  end

  test "respects formats option for generating specific layouts only" do
    run_generator %w[--formats=html json]

    assert_file "app/views/layouts/agent.html.erb"
    assert_file "app/views/layouts/agent.json.erb"
    assert_no_file "app/views/layouts/agent.text.erb"
  end

  test "respects formats option for single format" do
    run_generator %w[--formats=html]

    assert_file "app/views/layouts/agent.html.erb"
    assert_no_file "app/views/layouts/agent.text.erb"
    assert_no_file "app/views/layouts/agent.json.erb"
  end

  test "uses default text format when no formats specified" do
    run_generator

    assert_file "app/views/layouts/agent.text.erb"
    assert_no_file "app/views/layouts/agent.html.erb"
    assert_no_file "app/views/layouts/agent.json.erb"
  end

  test "handles erb generator override with proactive detection" do
    original_template_engine = Rails::Generators.options[:rails][:template_engine]
    Rails::Generators.options[:rails][:template_engine] = :nonexistent

    begin
      run_generator

      # Verify proactive detection created the layout file
      assert_file "app/views/layouts/agent.text.erb"
    ensure
      # Restore original template engine
      Rails::Generators.options[:rails][:template_engine] = original_template_engine
    end
  end
end
