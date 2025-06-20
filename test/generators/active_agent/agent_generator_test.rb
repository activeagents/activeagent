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

  test "invokes default template engine" do
    run_generator %w[user welcome activate]

    assert_file "app/views/user_agent/welcome.text.erb" do |view|
      assert_match(/welcome/, view)
    end

    assert_file "app/views/user_agent/welcome.html.erb" do |view|
      assert_match(/welcome/, view)
    end

    assert_file "app/views/user_agent/activate.text.erb" do |view|
      assert_match(/activate/, view)
    end

    assert_file "app/views/user_agent/activate.html.erb" do |view|
      assert_match(/activate/, view)
    end
  end

  test "invokes default test framework" do
    run_generator %w[user welcome activate]

    assert_file "test/agents/user_agent_test.rb" do |test|
      assert_match(/class UserAgentTest < ActiveAgent::TestCase/, test)
      assert_match(/test "welcome"/, test)
      assert_match(/test "activate"/, test)
    end
  end

  test "creates layout files" do
    run_generator %w[user]

    assert_file "app/views/layouts/agent.text.erb" do |layout|
      assert_match(/<%= yield %>/, layout)
    end

    assert_file "app/views/layouts/agent.html.erb" do |layout|
      assert_match(/<%= yield %>/, layout)
    end
  end

  test "does not create layout files if they already exist" do
    FileUtils.mkdir_p(File.join(destination_root, "app/views/layouts"))
    File.write(File.join(destination_root, "app/views/layouts/agent.text.erb"), "# existing layout")

    run_generator %w[user]

    assert_file "app/views/layouts/agent.text.erb" do |layout|
      assert_match(/# existing layout/, layout)
    end
  end

  test "invokes template engine even with no actions" do
    run_generator %w[user]

    assert_file "app/views/user_agent"
  end

  test "creates views in nested namespace" do
    run_generator %w[admin/user welcome]

    assert_file "app/views/admin/user_agent/welcome.text.erb"
    assert_file "app/views/admin/user_agent/welcome.html.erb"
  end

  test "creates tests in nested namespace" do
    run_generator %w[admin/user welcome]

    assert_file "test/agents/admin/user_agent_test.rb" do |test|
      assert_match(/class Admin::UserAgentTest < ActiveAgent::TestCase/, test)
    end
  end
end
