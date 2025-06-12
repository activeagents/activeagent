require "test_helper"
require "generators/active_agent/agent_generator"

class ActiveAgent::Generators::AgentGeneratorTest < Rails::Generators::TestCase
  tests ActiveAgent::Generators::AgentGenerator
  destination Rails.root.join("tmp/generators")
  setup :prepare_destination

  test "creates agent file with correct naming" do
    run_generator %w[user]

    assert_file "app/agents/user_agent.rb" do |content|
      assert_match(/class UserAgent/, content)
    end
  end

  test "creates agent file with actions" do
    run_generator %w[user welcome activate]

    assert_file "app/agents/user_agent.rb" do |content|
      assert_match(/class UserAgent/, content)
    end
  end

  test "creates agent file in nested namespace" do
    run_generator %w[admin/user]

    assert_file "app/agents/admin/user_agent.rb" do |content|
      assert_match(/class Admin::UserAgent/, content)
    end
  end

  test "creates application agent if it doesn't exist" do
    run_generator %w[user]

    assert_file "app/agents/application_agent.rb"
    assert_file "app/agents/user_agent.rb"
  end

  test "doesn't create application agent if it already exists" do
    FileUtils.mkdir_p(File.join(destination_root, "app/agents"))
    File.write(File.join(destination_root, "app/agents/application_agent.rb"), "# existing file")

    run_generator %w[user]

    assert_file "app/agents/application_agent.rb" do |content|
      assert_match(/# existing file/, content)
    end
  end

  test "handles revoke behavior" do
    run_generator %w[user]
    assert_file "app/agents/user_agent.rb"

    run_generator %w[user], behavior: :revoke
    assert_no_file "app/agents/user_agent.rb"
  end
end
