require "test_helper"
require "generators/active_agent/agent/agent_generator"

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

  test "invokes template engine hook with markdown by default" do
    run_generator %w[user create]

    assert_file "app/agents/user_agent.rb"
    assert_file "app/views/agents/user/create.md.erb"
  end

  test "handles class collision checking" do
    # This test verifies that class collision checking is available
    # The actual collision behavior depends on Rails internals
    generator = ActiveAgent::Generators::AgentGenerator.new([ "user" ])
    assert_respond_to generator, :check_class_collision
  end

  test "respects format option for text" do
    run_generator %w[user create --format=text]

    assert_file "app/agents/user_agent.rb"
    assert_file "app/views/agents/user/create.text.erb"
    assert_no_file "app/views/agents/user/create.md.erb"
  end

  test "uses default markdown format when no format option provided" do
    run_generator [ "user", "create" ]

    assert_file "app/agents/user_agent.rb"
    assert_file "app/views/agents/user/create.md.erb"
    assert_no_file "app/views/agents/user/create.text.erb"
  end

  test "generates schema files when json_schema flag is set" do
    run_generator %w[user create --json-schema]

    assert_file "app/agents/user_agent.rb"
    assert_file "app/views/agents/user/create.md.erb"
    assert_file "app/views/agents/user/create.schema.json"
  end

  test "does not generate schema files without json_schema flag" do
    run_generator %w[user create]

    assert_file "app/views/agents/user/create.md.erb"
    assert_no_file "app/views/agents/user/create.schema.json"
  end

  test "handles multiple actions with json_schema" do
    run_generator %w[user create update --json-schema]

    assert_file "app/views/agents/user/create.md.erb"
    assert_file "app/views/agents/user/create.schema.json"
    assert_file "app/views/agents/user/update.md.erb"
    assert_file "app/views/agents/user/update.schema.json"
  end

  test "generates view files with correct content" do
    run_generator %w[user create]

    assert_file "app/views/agents/user/create.md.erb" do |content|
      assert_match(/User#create/, content)
    end
  end

  test "format option works with nested generators" do
    run_generator %w[admin/user create --format=text]

    assert_file "app/views/agents/admin/user/create.text.erb"
    assert_no_file "app/views/agents/admin/user/create.md.erb"
  end

  test "handles erb generator override with proactive detection" do
    original_template_engine = Rails::Generators.options[:rails][:template_engine]
    Rails::Generators.options[:rails][:template_engine] = :nonexistent

    begin
      run_generator %w[user create]

      assert_file "app/agents/user_agent.rb"
      assert_file "app/views/agents/user/create.md.erb"
    ensure
      # Restore original template engine
      Rails::Generators.options[:rails][:template_engine] = original_template_engine
    end
  end

  test "generates default prompt format without response_format" do
    run_generator %w[user create]

    assert_file "app/agents/user_agent.rb" do |content|
      assert_match(/def create/, content)
      assert_match(/prompt\(params\[:message\]\)/, content)
      assert_no_match(/response_format/, content)
    end
  end

  test "generates prompt with json_schema response_format when flag is set" do
    run_generator %w[user create --json-schema]

    assert_file "app/agents/user_agent.rb" do |content|
      assert_match(/def create/, content)
      assert_match(/prompt\(params\[:message\], response_format: :json_schema\)/, content)
    end
  end

  test "generates prompt with json_object response_format when flag is set" do
    run_generator %w[user create --json-object]

    assert_file "app/agents/user_agent.rb" do |content|
      assert_match(/def create/, content)
      assert_match(/prompt\(params\[:message\], response_format: :json_object\)/, content)
    end
  end

  test "does not generate schema files with json_object flag" do
    run_generator %w[user create --json-object]

    assert_file "app/agents/user_agent.rb"
    assert_file "app/views/agents/user/create.md.erb"
    assert_no_file "app/views/agents/user/create.schema.json"
  end

  test "handles multiple actions with json_object" do
    run_generator %w[user create update --json-object]

    assert_file "app/agents/user_agent.rb" do |content|
      assert_match(/def create/, content)
      assert_match(/prompt\(params\[:message\], response_format: :json_object\)/, content)
      assert_match(/def update/, content)
    end
    assert_no_file "app/views/agents/user/create.schema.json"
    assert_no_file "app/views/agents/user/update.schema.json"
  end

  private

  def create_file(path, content)
    full_path = File.join(destination_root, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, content)
  end
end
