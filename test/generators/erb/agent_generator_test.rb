require "test_helper"
require "generators/erb/agent_generator"

class Erb::Generators::AgentGeneratorTest < Rails::Generators::TestCase
  tests Erb::Generators::AgentGenerator
  destination Rails.root.join("tmp/generators")
  setup :prepare_destination

  test "generates markdown view files for actions by default" do
    run_generator [ "user", "create", "update" ]

    assert_file "app/views/user_agent/create.md.erb"
    assert_file "app/views/user_agent/update.md.erb"
  end

  test "generates text view files when format is text" do
    run_generator [ "user", "create", "--format=text" ]

    assert_file "app/views/user_agent/create.text.erb"
    assert_no_file "app/views/user_agent/create.md.erb"
  end

  test "generates view files with correct content" do
    run_generator [ "user", "create" ]

    assert_file "app/views/user_agent/create.md.erb" do |content|
      assert_match(/User#create/, content)
    end
  end

  test "generates nested view files" do
    run_generator [ "admin/user", "create" ]

    assert_file "app/views/admin/user_agent/create.md.erb"
  end

  test "does not generate view files without actions" do
    run_generator [ "user" ]

    # Directory is created with instructions only
    assert_directory "app/views/user_agent"
    assert_file "app/views/user_agent/instructions.md.erb"
    assert_no_file "app/views/user_agent/create.md.erb"
  end

  test "generates schema files when json_schema flag is set" do
    run_generator [ "user", "create", "--json-schema" ]

    assert_file "app/views/user_agent/create.schema.json" do |content|
      assert_match(/"type": "object"/, content)
      assert_match(/"properties"/, content)
    end
  end

  test "generates multiple schema files for multiple actions" do
    run_generator [ "user", "create", "update", "--json-schema" ]

    assert_file "app/views/user_agent/create.schema.json"
    assert_file "app/views/user_agent/update.schema.json"
  end

  test "does not generate schema files without json_schema flag" do
    run_generator [ "user", "create" ]

    assert_no_file "app/views/user_agent/create.schema.json"
  end

  test "adds instruction view to agents view directory with markdown by default" do
    run_generator [ "user" ]

    assert_directory "app/views/user_agent"
    assert_file "app/views/user_agent/instructions.md.erb"
  end

  test "adds instruction view with text format when specified" do
    run_generator [ "user", "--format=text" ]

    assert_file "app/views/user_agent/instructions.text.erb"
    assert_no_file "app/views/user_agent/instructions.md.erb"
  end

  test "handles erb generator override with proactive detection" do
    original_template_engine = Rails::Generators.options[:rails][:template_engine]
    Rails::Generators.options[:rails][:template_engine] = :nonexistent

    begin
      run_generator %w[user create]

      assert_file "app/views/user_agent/create.md.erb"
    ensure
      # Restore original template engine
      Rails::Generators.options[:rails][:template_engine] = original_template_engine
    end
  end
end
