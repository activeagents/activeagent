require "test_helper"
require "generators/active_agent/agent_generator"

class ActiveAgent::Generators::AgentGeneratorTest < Rails::Generators::TestCase
  tests ActiveAgent::Generators::AgentGenerator
  destination Rails.root.join("tmp/generators")
  setup :prepare_destination

  test "generates agent file" do
    run_generator [ "user" ]

    assert_file "app/agents/user_agent.rb" do |content|
      assert_match(/class UserAgent < ApplicationAgent/, content)
    end
  end

  test "generates agent file with actions" do
    run_generator [ "user", "create", "update" ]

    assert_file "app/agents/user_agent.rb" do |content|
      assert_match(/class UserAgent < ApplicationAgent/, content)
      assert_match(/def create/, content)
      assert_match(/def update/, content)
    end
  end

  test "creates application agent if not exists" do
    run_generator [ "user" ]

    assert_file "app/agents/application_agent.rb" do |content|
      assert_match(/class ApplicationAgent < ActiveAgent::Base/, content)
      assert_match(/layout "agent"/, content)
    end
  end

  test "does not overwrite existing application agent" do
    create_file "app/agents/application_agent.rb", "# existing file"

    run_generator [ "user" ]

    assert_file "app/agents/application_agent.rb", "# existing file"
  end

  test "generates agent with namespace" do
    run_generator [ "admin/user" ]

    assert_file "app/agents/admin/user_agent.rb" do |content|
      assert_match(/class Admin::UserAgent < ApplicationAgent/, content)
    end
  end

  test "invokes template engine hook" do
    run_generator [ "user", "create", "--template-engine=erb" ]

    assert_file "app/agents/user_agent.rb"
    assert_file "app/views/user_agent/create.html.erb"
    assert_file "app/views/user_agent/create.text.erb"
  end

  test "invokes test framework hook" do
    run_generator [ "user", "create", "--test-framework=test_unit" ]

    assert_file "app/agents/user_agent.rb"
    assert_file "test/agents/user_agent_test.rb"
    assert_file "test/agents/previews/user_agent_preview.rb"
  end

  test "handles class collision checking" do
    # This test verifies that class collision checking is available
    # The actual collision behavior depends on Rails internals
    generator = ActiveAgent::Generators::AgentGenerator.new([ "user" ])
    assert_respond_to generator, :check_class_collision
  end

  private

  def create_file(path, content)
    full_path = File.join(destination_root, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, content)
  end
end
