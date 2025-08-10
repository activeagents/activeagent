require "test_helper"
require "generators/erb/agent_generator"

class Erb::Generators::AgentGeneratorTest < Rails::Generators::TestCase
  tests Erb::Generators::AgentGenerator
  destination Rails.root.join("tmp/generators")
  setup :prepare_destination

  test "generates view files for actions" do
    run_generator [ "user", "create", "update" ]

    assert_file "app/views/user_agent/create.text.erb"
    assert_file "app/views/user_agent/update.text.erb"
  end

  test "generates view files with correct content" do
    run_generator [ "user", "create" ]

    assert_file "app/views/user_agent/create.text.erb" do |content|
      assert_match(/User#create/, content)
    end
  end

  test "generates nested view files" do
    run_generator [ "admin/user", "create" ]

    assert_file "app/views/admin/user_agent/create.text.erb"
  end

  test "does not generate view files without actions" do
    run_generator [ "user" ]

    # Directory is created but should be empty
    assert_directory "app/views/user_agent"
    assert_no_file "app/views/user_agent/create.html.erb"
  end

  test "generates json view files with function schema structure" do
    run_generator [ "user", "create", "--formats=json" ]

    assert_file "app/views/user_agent/create.json.erb" do |content|
      assert_match(/type: :function/, content)
      assert_match(/function:/, content)
      assert_match(/name: action_name/, content)
      assert_match(/description:/, content)
      assert_match(/parameters:/, content)
      assert_match(/type: :object/, content)
      assert_match(/properties:/, content)
    end
  end

  test "adds intruction view to agents view directory " do
    run_generator [ "user" ]

    assert_directory "app/views/user_agent"
    assert_file "app/views/user_agent/instructions.text.erb"
  end
end
