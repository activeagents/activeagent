require "test_helper"
require "generators/erb/agent_generator"

class Erb::Generators::AgentGeneratorTest < Rails::Generators::TestCase
  tests Erb::Generators::AgentGenerator
  destination Rails.root.join("tmp/generators")
  setup :prepare_destination

  test "generates view files for actions" do
    run_generator ["user", "create", "update"]

    assert_file "app/views/user_agent/create.html.erb"
    assert_file "app/views/user_agent/create.text.erb"
    assert_file "app/views/user_agent/update.html.erb"
    assert_file "app/views/user_agent/update.text.erb"
  end

  test "generates view files with correct content" do
    run_generator ["user", "create"]

    assert_file "app/views/user_agent/create.html.erb" do |content|
      assert_match(/User#create/, content)
      assert_match(/<%= @message %>/, content) # Should be unescaped in the final file
    end

    assert_file "app/views/user_agent/create.text.erb" do |content|
      assert_match(/User#create/, content)
    end
  end

  test "generates nested view files" do
    run_generator ["admin/user", "create"]

    assert_file "app/views/admin/user_agent/create.html.erb"
    assert_file "app/views/admin/user_agent/create.text.erb"
  end

  test "does not generate view files without actions" do
    run_generator ["user"]

    # Directory is created but should be empty
    assert_file "app/views/user_agent"
    assert_no_file "app/views/user_agent/index.html.erb"
    assert_no_file "app/views/user_agent/show.html.erb"
  end
end
