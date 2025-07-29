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
    run_generator %w[user create]

    assert_file "app/agents/user_agent.rb"
    assert_file "app/views/user_agent/create.text.erb"
  end

  test "handles class collision checking" do
    # This test verifies that class collision checking is available
    # The actual collision behavior depends on Rails internals
    generator = ActiveAgent::Generators::AgentGenerator.new([ "user" ])
    assert_respond_to generator, :check_class_collision
  end

  test "respects formats option" do
    run_generator %w[user create --formats=html json]

    assert_file "app/agents/user_agent.rb"
    # This test ensures the formats option is passed to template engine hooks
    # The actual format handling is tested in the ERB generator tests
  end

  test "uses default formats when no formats option provided" do
    run_generator [ "user", "create" ]

    assert_file "app/agents/user_agent.rb"
    # Default behavior should work as before
  end

  test "passes formats option with text and html" do
    run_generator %w[user create --formats=html text]

    assert_file "app/agents/user_agent.rb"
    assert_file "app/views/user_agent/create.html.erb"
    assert_file "app/views/user_agent/create.text.erb"
    # Should not create json file when not specified
    assert_no_file "app/views/user_agent/create.json.erb"
  end

  test "respects formats option for generating specific formats only" do
    run_generator %w[user create --formats=html text]

    assert_file "app/views/user_agent/create.html.erb"
    assert_file "app/views/user_agent/create.text.erb"
    assert_no_file "app/views/user_agent/create.json.erb"
  end

  test "respects formats option for single format" do
    run_generator %w[user create --formats=json]

    assert_no_file "app/views/user_agent/create.html.erb"
    assert_no_file "app/views/user_agent/create.text.erb"
    assert_file "app/views/user_agent/create.json.erb"
  end

  test "uses default text format when no formats specified" do
    run_generator [ "user", "create" ]

    assert_file "app/views/user_agent/create.text.erb"
    assert_no_file "app/views/user_agent/create.html.erb"
    assert_no_file "app/views/user_agent/create.json.erb"
  end

  test "handles multiple actions with custom formats" do
    run_generator %w[user create update --formats=html json]

    assert_file "app/views/user_agent/create.html.erb"
    assert_file "app/views/user_agent/create.json.erb"
    assert_file "app/views/user_agent/update.html.erb"
    assert_file "app/views/user_agent/update.json.erb"
    assert_no_file "app/views/user_agent/create.text.erb"
    assert_no_file "app/views/user_agent/update.text.erb"
  end

  test "generates view files with correct content in the specified formats" do
    run_generator %w[user create --formats=html json]

    assert_file "app/views/user_agent/create.html.erb" do |content|
      assert_match(/User#create/, content)
      assert_match(/<%= @message %>/, content) # Should be unescaped in the final file
    end

    assert_file "app/views/user_agent/create.json.erb" do |content|
      assert_match(/action_name/, content)
      assert_match(/function/, content)
      assert_match(/\.to_json\.html_safe/, content)
    end
  end

  test "formats option works with nested generators" do
    run_generator %w[admin/user create --formats=html]

    assert_file "app/views/admin/user_agent/create.html.erb"
    assert_no_file "app/views/admin/user_agent/create.text.erb"
    assert_no_file "app/views/admin/user_agent/create.json.erb"
  end

  private

  def create_file(path, content)
    full_path = File.join(destination_root, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, content)
  end
end
