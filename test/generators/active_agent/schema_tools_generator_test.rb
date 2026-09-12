# frozen_string_literal: true

require "test_helper"
require "generators/active_agent/schema_tools/schema_tools_generator"

class ActiveAgent::Generators::SchemaToolsGeneratorTest < Rails::Generators::TestCase
  tests ActiveAgent::Generators::SchemaToolsGenerator
  destination Rails.root.join("tmp/generators")
  setup :prepare_destination

  test "writes a tools class that exposes only id until a column is chosen" do
    run_generator [ "post" ]

    assert_file "app/agent_tools/post_tools.rb" do |content|
      assert_match(/class PostTools < ActiveAgent::SchemaTools/, content)
      assert_match(/^\s+model Post$/, content)
      assert_match(/^\s+filterable :id$/, content)
      assert_match(/^\s+returns :id$/, content)
    end
  end

  test "lists the model's columns, commented out, with their types" do
    run_generator [ "Post" ]

    assert_file "app/agent_tools/post_tools.rb" do |content|
      filterable = content[/^\s+# filterable (.+)$/, 1]
      returns = content[/^\s+# returns (.+)$/, 1]
      %w[:title :content :published :published_at :user_id :created_at :updated_at].each do |column|
        assert_includes filterable, column
        assert_includes returns, column
      end
      assert_no_match(/:id\b/, filterable, "id is already declared, not a suggestion")
      assert_match(/#\s+published\s+boolean/, content)
      assert_match(/#\s+title\s+string/, content)
      assert_no_match(/^\s+filterable :title/, content, "a column must be chosen, not pre-selected")
    end
  end

  test "accepts the Tools suffix and a namespace" do
    run_generator [ "PostTools" ]
    assert_file "app/agent_tools/post_tools.rb", /class PostTools < ActiveAgent::SchemaTools/

    run_generator [ "admin/post" ]
    assert_file "app/agent_tools/admin/post_tools.rb" do |content|
      assert_match(/class Admin::PostTools < ActiveAgent::SchemaTools/, content)
      assert_match(/model Admin::Post/, content)
    end
  end

  test "suggests a scope block when no policy exists, and scope_by_policy on request" do
    run_generator [ "post" ]
    assert_file "app/agent_tools/post_tools.rb" do |content|
      assert_match(/# scope \{ \|actor\| actor \? Post\.where\(owner: actor\) : Post\.none \}/, content)
      assert_no_match(/^\s+scope_by_policy/, content)
    end

    run_generator [ "post", "--policy", "--force" ]
    assert_file "app/agent_tools/post_tools.rb" do |content|
      assert_match(/^\s+scope_by_policy$/, content)
      assert_match(/PostPolicy::Scope/, content)
    end
  end

  test "a model that does not exist yet still gets a file, with placeholders" do
    run_generator [ "widget" ]

    assert_file "app/agent_tools/widget_tools.rb" do |content|
      assert_match(/model Widget/, content)
      assert_match(/# filterable :status, :owner_id/, content)
      assert_match(/# returns :id, :title, :status/, content)
    end
  end

  test "secret-shaped columns are never suggested" do
    column = Struct.new(:name, :type)
    secretive = Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      def self.name = "Member"
      define_singleton_method(:columns) { super() + [ column.new("password_digest", :string), column.new("api_token", :string) ] }
    end
    Object.const_set(:Member, secretive)

    run_generator [ "member" ]

    assert_file "app/agent_tools/member_tools.rb" do |content|
      assert_no_match(/:password_digest|:api_token/, content)
      assert_match(/Not suggested, and not to be added: password_digest, api_token/, content)
      assert_includes content[/^\s+# returns (.+)$/, 1], ":email"
    end
  ensure
    Object.send(:remove_const, :Member) if Object.const_defined?(:Member)
  end
end
