require "test_helper"
require "generators/test_unit/agent_generator"

class TestUnit::Generators::AgentGeneratorTest < Rails::Generators::TestCase
  tests TestUnit::Generators::AgentGenerator
  destination Rails.root.join("tmp/generators")
  setup :prepare_destination

  test "generates test files" do
    run_generator ["user", "create", "update"]

    assert_file "test/agents/user_agent_test.rb" do |content|
      assert_match(/class UserAgentTest < ActiveAgent::TestCase/, content)
      assert_match(/test "create"/, content)
      assert_match(/test "update"/, content)
    end
  end

  test "generates preview files" do
    run_generator ["user", "create", "update"]

    assert_file "test/agents/previews/user_agent_preview.rb" do |content|
      assert_match(/class UserAgentPreview < ActiveAgent::Preview/, content)
      assert_match(/def create/, content)
      assert_match(/def update/, content)
    end
  end

  test "generates files with namespace" do
    run_generator ["admin/user", "create"]

    assert_file "test/agents/admin/user_agent_test.rb" do |content|
      assert_match(/class Admin::UserAgentTest < ActiveAgent::TestCase/, content)
    end

    assert_file "test/agents/previews/admin/user_agent_preview.rb" do |content|
      assert_match(/class Admin::UserAgentPreview < ActiveAgent::Preview/, content)
    end
  end

  test "handles class collision check" do
    # The generator should check for class collisions
    assert_respond_to TestUnit::Generators::AgentGenerator.new(["user"]), :check_class_collision
  end

  test "strips agent suffix from file name" do
    run_generator ["user_agent", "create"]

    assert_file "test/agents/user_agent_test.rb" do |content|
      assert_match(/class UserAgentTest < ActiveAgent::TestCase/, content)
    end
  end

  test "generates test without actions" do
    run_generator ["user"]

    assert_file "test/agents/user_agent_test.rb" do |content|
      assert_match(/class UserAgentTest < ActiveAgent::TestCase/, content)
      assert_no_match(/^  test "/, content) # No actual test methods (only commented ones)
    end

    assert_file "test/agents/previews/user_agent_preview.rb" do |content|
      assert_match(/class UserAgentPreview < ActiveAgent::Preview/, content)
      assert_no_match(/def [a-z]/, content) # No action methods
    end
  end
end
