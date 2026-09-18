# frozen_string_literal: true

require "test_helper"
require "active_agent/schema_tools"

# Load the dummy app's models
require_relative "dummy/app/models/application_record"
require_relative "dummy/app/models/user"
require_relative "dummy/app/models/post"

class SchemaToolsTest < ActiveSupport::TestCase
  # region user_tools
  class UserTools < ActiveAgent::SchemaTools
    model User
    filterable :role, :active
    returns :id, :name, :email, :role
  end
  # endregion user_tools

  # region post_tools_with_scope
  class ScopedPostTools < ActiveAgent::SchemaTools
    model Post
    filterable :user, :published
    returns :id, :title, :published

    # The host's authorization seam: whatever relation this returns is what
    # the generated tools query through.
    scope { |actor| actor ? actor.posts : Post.none }
  end
  # endregion post_tools_with_scope

  # No `scope` declared — tools run unscoped, which is the host's choice.
  class UnscopedPostTools < ActiveAgent::SchemaTools
    model Post
    filterable :published
    returns :id, :title
  end

  # A Rails enum, which is declared on the model rather than through the
  # inclusion validator SchemaGenerator reads.
  class EnumPost < Post
    self.table_name = "posts"
    enum :state, { draft: 0, review: 1, live: 2 }, prefix: true

    def self.name = "EnumPost"
  end

  class EnumPostTools < ActiveAgent::SchemaTools
    model EnumPost
    filterable :state, :published
    returns :id, :title
  end

  setup do
    Post.delete_all
    Profile.delete_all if defined?(Profile)
    User.delete_all

    @alice = User.create!(name: "Alice", email: "alice@example.com", age: 30, role: "admin", active: true)
    @bob   = User.create!(name: "Bob", email: "bob@example.com", age: 25, role: "user", active: true)
    @carol = User.create!(name: "Carol", email: "carol@example.com", age: 40, role: "user", active: false)

    @alice_post = Post.create!(user: @alice, title: "Alice post", content: "body", published: true)
    @bob_post   = Post.create!(user: @bob, title: "Bob post", content: "body", published: false)
  end

  teardown do
    Post.delete_all
    User.delete_all
  end

  # --- Roster generation -------------------------------------------------

  test "generates a fixed, enumerable tool roster" do
    # region enumerate_tools
    names = UserTools.tool_definitions.map { |definition| definition[:name] }
    # endregion enumerate_tools

    assert_equal [ "find_users", "count_users", "get_user" ], names
  end

  test "tool roster is enumerable without invoking any tool" do
    # This is the property method_missing cannot provide: MCP tools/list and
    # the dashboard both need the roster before any call happens.
    assert_equal 3, UserTools.tool_definitions.size
    assert UserTools.tool?("find_users")
    refute UserTools.tool?("delete_users")
  end

  test "generated tools are real methods, not method_missing" do
    assert_respond_to UserTools, :find_users
    assert UserTools.singleton_class.method_defined?(:find_users)
    refute UserTools.respond_to?(:find_nonexistent_things)
  end

  test "only read-only tools are generated" do
    write_verbs = %w[create update delete destroy insert]

    UserTools.tool_names.each do |name|
      write_verbs.each do |verb|
        refute_includes name, verb, "#{name} looks like a write tool"
      end
    end
  end

  test "tool definitions use provider function-calling format" do
    definition = UserTools.tool_definitions.find { |d| d[:name] == "find_users" }

    assert_equal "object", definition[:parameters][:type]
    assert_kind_of Hash, definition[:parameters][:properties]
    assert_kind_of Array, definition[:parameters][:required]
    assert definition[:description].present?
  end

  test "filter parameter schemas come from SchemaGenerator" do
    definition = UserTools.tool_definitions.find { |d| d[:name] == "find_users" }
    properties = definition[:parameters][:properties]

    # role has an inclusion validator on User, which SchemaGenerator turns
    # into an enum — hand-rolled type mapping would not know that.
    assert_equal [ "admin", "moderator", "user" ], properties[:role][:enum]
    assert_equal "boolean", properties[:active][:type]
  end

  test "a Rails enum is offered as its names, not its integer backing" do
    definition = EnumPostTools.tool_definitions.find { |d| d[:name] == "find_enum_posts" }
    state = definition[:parameters][:properties][:state]

    # Without this the column reaches the model as {type: "integer"}: no
    # labels, so the only way a model learns "review" means 1 is prose in the
    # instructions, written by hand in every host app.
    assert_equal "string", state[:type]
    assert_equal [ "draft", "review", "live" ], state[:enum]
  end

  test "an enum is not offered the range form" do
    definition = EnumPostTools.tool_definitions.find { |d| d[:name] == "find_enum_posts" }
    state = definition[:parameters][:properties][:state]

    # `state > 1` is an artefact of declaration order, not a question anyone
    # can ask. Offering it invites a filter that returns a confident number.
    refute state.key?(:anyOf), "an enum must not advertise comparisons"
  end

  test "an undefined enum value is rejected rather than matching nothing" do
    result = EnumPostTools.call("count_enum_posts", state: "pending")

    # The silent alternative is {count: 0}, which an agent reports as a fact:
    # "no posts are pending" reads identically to "pending is not a state".
    # Same shape as the unknown-column error, so the model can correct itself.
    refute result.key?(:count), "an undefined enum value must not return a count"
    assert_match "pending", result[:error]
    assert_match "draft, review, live", result[:error]
  end

  test "an enum still accepts the names and values it defines" do
    # setup seeds two posts, both at the column default (draft).
    EnumPost.create!(title: "Live one", content: "x", user: @alice, state: "live")

    assert_equal({ count: 2 }, EnumPostTools.call("count_enum_posts", state: "draft"))
    assert_equal({ count: 1 }, EnumPostTools.call("count_enum_posts", state: "live"))
    # The integer backing still works, so a stored value round-trips.
    assert_equal({ count: 1 }, EnumPostTools.call("count_enum_posts", state: 2))
  end

  test "a range predicate on an enum is rejected" do
    result = EnumPostTools.call("count_enum_posts", state: { "gt" => 1 })

    refute result.key?(:count), "a comparison on an enum must not return a count"
    assert_match "cannot be compared as a range", result[:error]
  end

  test "only filterable columns appear as find parameters" do
    definition = UserTools.tool_definitions.find { |d| d[:name] == "find_users" }
    properties = definition[:parameters][:properties]

    assert properties.key?(:role)
    assert properties.key?(:active)
    assert properties.key?(:limit)
    refute properties.key?(:email), "email is not filterable and must not be offered"
    refute properties.key?(:age)
  end

  test "belongs_to association names resolve to foreign keys" do
    definition = ScopedPostTools.tool_definitions.find { |d| d[:name] == "find_posts" }

    assert definition[:parameters][:properties].key?(:user_id)
    assert_includes ScopedPostTools.filterable, :user_id
  end

  # --- Security boundary: filters ----------------------------------------

  test "rejects a filter on an undeclared column" do
    # region rejects_undeclared_filter
    result = UserTools.call("find_users", email: "alice@example.com")
    # endregion rejects_undeclared_filter

    assert result[:error].present?, "expected an error, got #{result.inspect}"
    assert_includes result[:error], "email"
    refute result.key?(:results), "must not return records when a filter is rejected"
  end

  test "rejects rather than silently ignores an undeclared filter" do
    # Silently dropping the filter would answer a broader question than was
    # asked while looking like a success.
    unfiltered = UserTools.call("find_users")
    rejected = UserTools.call("find_users", age: 30)

    assert_equal 3, unfiltered[:count]
    assert rejected[:error].present?
    refute_equal 3, rejected[:count]
  end

  test "rejects a filter on a sensitive undeclared column" do
    result = UserTools.call("count_users", name: "Alice")

    assert result[:error].present?
    refute result.key?(:count)
  end

  test "undeclared columns cannot be declared filterable" do
    error = assert_raises(ActiveAgent::SchemaTools::UnpermittedAttribute) do
      Class.new(ActiveAgent::SchemaTools) do
        model User
        filterable :password_digest
      end
    end

    assert_includes error.message, "password_digest"
  end

  # --- Security boundary: returned columns -------------------------------

  test "does not leak undeclared columns in find results" do
    # region bounded_return_columns
    result = UserTools.call("find_users", role: "user")
    # endregion bounded_return_columns

    record = result[:results].first
    assert_equal %i[id name email role], record.keys
    refute record.key?(:age), "age is not declared in returns and must not leak"
    refute record.key?(:created_at)
  end

  test "does not leak undeclared columns in get results" do
    result = UserTools.call("get_user", id: @alice.id)

    assert_equal %i[id name email role], result.keys
    refute result.key?(:active)
  end

  test "returns only declared columns even when the scope selects more" do
    tools = Class.new(ActiveAgent::SchemaTools) do
      model Post
      filterable :published
      returns :id, :title
      # A scope that hands back fully loaded records — the Ruby-side
      # projection is what actually enforces the boundary.
      scope { Post.all }
    end

    record = tools.call("find_posts", published: true)[:results].first

    assert_equal %i[id title], record.keys
    refute record.key?(:content)
  end

  # --- Result bounding ---------------------------------------------------

  test "find with no filters is bounded by the default limit" do
    50.times { |i| Post.create!(user: @alice, title: "Post #{i}", content: "body") }

    result = UnscopedPostTools.call("find_posts")

    assert_equal ActiveAgent::SchemaTools::DEFAULT_LIMIT, result[:count]
    assert result[:truncated], "truncation must be visible to the model"
  end

  test "limit is capped at MAX_LIMIT regardless of what the caller asks for" do
    200.times { |i| Post.create!(user: @alice, title: "Post #{i}", content: "body") }

    result = UnscopedPostTools.call("find_posts", limit: 10_000)

    assert_equal ActiveAgent::SchemaTools::MAX_LIMIT, result[:count]
    assert result[:truncated]
  end

  test "truncated is false when results fit inside the limit" do
    result = UnscopedPostTools.call("find_posts")

    assert_equal 2, result[:count]
    refute result[:truncated]
  end

  test "an explicit smaller limit is honored" do
    result = UnscopedPostTools.call("find_posts", limit: 1)

    assert_equal 1, result[:count]
    assert result[:truncated]
  end

  # --- Scope seam --------------------------------------------------------

  test "scope block is invoked with the actor" do
    received = nil
    tools = Class.new(ActiveAgent::SchemaTools) do
      model Post
      filterable :published
      returns :id, :title
      scope { |actor| received = actor; Post.where(user: actor) }
    end

    tools.call("find_posts", actor: @alice)

    assert_equal @alice, received
  end

  test "scope restricts which records tools can reach" do
    # region scoped_tools
    alice_results = ScopedPostTools.call("find_posts", actor: @alice)
    bob_results   = ScopedPostTools.call("find_posts", actor: @bob)
    # endregion scoped_tools

    assert_equal [ "Alice post" ], alice_results[:results].map { |r| r[:title] }
    assert_equal [ "Bob post" ], bob_results[:results].map { |r| r[:title] }
  end

  test "get through a scope cannot reach a record outside it" do
    # Must read as "not found", not as a permission signal.
    result = ScopedPostTools.call("get_post", actor: @bob, id: @alice_post.id)

    assert result[:error].present?
    assert_includes result[:error], "No post found"
  end

  test "scope receiving a nil actor returns nothing when the host says so" do
    result = ScopedPostTools.call("find_posts", actor: nil)

    assert_equal 0, result[:count]
    assert_empty result[:results]
  end

  test "tools run unscoped when no scope block is declared" do
    # An absent scope is a legitimate host choice, not a default to fight.
    result = UnscopedPostTools.call("find_posts")

    assert_equal 2, result[:count]
    assert_nil UnscopedPostTools.scope
  end

  # --- Tool behavior -----------------------------------------------------

  test "find filters on a declared column" do
    result = UserTools.call("find_users", role: "user")

    assert_equal 2, result[:count]
    assert_equal %w[Bob Carol], result[:results].map { |r| r[:name] }.sort
  end

  test "find combines multiple declared filters" do
    result = UserTools.call("find_users", role: "user", active: true)

    assert_equal 1, result[:count]
    assert_equal "Bob", result[:results].first[:name]
  end

  test "count returns a bare count for declared filters" do
    result = UserTools.call("count_users", role: "user")

    assert_equal 2, result[:count]
  end

  test "count with no filters counts everything in scope" do
    assert_equal 3, UserTools.call("count_users")[:count]
  end

  test "get returns a single projected record" do
    result = UserTools.call("get_user", id: @alice.id)

    assert_equal "Alice", result[:name]
    assert_equal "admin", result[:role]
  end

  test "get returns an error for a missing record" do
    result = UserTools.call("get_user", id: 999_999)

    assert result[:error].present?
  end

  test "get requires an id" do
    assert UserTools.call("get_user")[:error].present?
  end

  test "call returns an error for an unknown tool name" do
    result = UserTools.call("drop_users")

    assert_includes result[:error], "Unknown tool"
  end

  test "datetime values are serialized as iso8601 strings" do
    tools = Class.new(ActiveAgent::SchemaTools) do
      model Post
      filterable :published
      returns :id, :created_at
    end

    created_at = tools.call("find_posts")[:results].first[:created_at]

    assert_kind_of String, created_at
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, created_at)
  end

  # --- Declaration errors ------------------------------------------------

  test "declaring a non-ActiveRecord model raises" do
    assert_raises(ArgumentError) do
      Class.new(ActiveAgent::SchemaTools) { model String }
    end
  end

  test "declaring columns before a model raises" do
    assert_raises(ActiveAgent::SchemaTools::MissingModel) do
      Class.new(ActiveAgent::SchemaTools) { returns :id }
    end
  end

  test "a subclass does not widen its parent's allowlist" do
    child = Class.new(UserTools) do
      filterable :role, :active, :age
    end

    assert_includes child.filterable, :age
    refute_includes UserTools.filterable, :age
  end
  class ScopedByPolicyPost < ActiveAgent::SchemaTools
    class FakePolicyScope
      def initialize(actor, scope) = (@actor, @scope = actor, scope)
      def resolve = @actor ? @scope.all : @scope.none
    end

    model Post
    filterable :title
    returns :id, :title
    scope_by_policy FakePolicyScope
  end

  # --- Runtime definitions ------------------------------------------------

  test "define builds a named, registered tool class from a declaration" do
    tools = ActiveAgent::SchemaTools.define(
      Post, filterable: %i[published], returns: %i[id title],
      scope: ->(actor) { actor ? actor.posts : Post.none }
    )

    assert_equal "PostTools", tools.name
    assert tools.runtime?
    assert_not UserTools.runtime?
    assert_equal %w[find_posts count_posts get_post], tools.tool_names
    assert_equal 1, tools.call("count_posts", actor: @alice)[:count]
    assert_equal 0, tools.call("count_posts", actor: nil)[:count]
    assert_same tools, ActiveAgent::SchemaTools.registry["Post"]
  ensure
    ActiveAgent::SchemaTools.undefine(Post)
  end

  test "redefining a model's tools replaces the previous class instead of adding one" do
    first = ActiveAgent::SchemaTools.define(Post, filterable: %i[published], returns: %i[id])
    second = ActiveAgent::SchemaTools.define(Post, filterable: %i[published], returns: %i[id title])

    assert_same second, ActiveAgent::SchemaTools.registry["Post"]
    assert_equal 1, ActiveAgent::SchemaTools.registry.count { |model_name, _| model_name == "Post" }
    assert_equal %w[id title], second.returns.map(&:to_s)
    assert first.runtime?, "a superseded class stays runtime-built, so discovery never reads it from descendants"
  ensure
    ActiveAgent::SchemaTools.undefine(Post)
  end

  test "define accepts a policy class and undefine drops the registration" do
    tools = ActiveAgent::SchemaTools.define(Post, returns: %i[id], policy: ScopedByPolicyPost::FakePolicyScope)

    assert_equal Post.count, tools.call("count_posts", actor: :someone)[:count]
    assert_equal 0, tools.call("count_posts", actor: nil)[:count]

    assert_same tools, ActiveAgent::SchemaTools.undefine(Post)
    assert_nil ActiveAgent::SchemaTools.registry["Post"]
    assert_nil ActiveAgent::SchemaTools.undefine("Post")
  end

  test "a runtime class enforces the same boundary as a file-defined one" do
    tools = ActiveAgent::SchemaTools.define(Post, filterable: %i[published], returns: %i[id title])

    assert_match(/not a filterable attribute/, tools.call("find_posts", user_id: 1)[:error])
    assert_equal %w[id title], tools.call("find_posts")[:results].first.keys.map(&:to_s)
  ensure
    ActiveAgent::SchemaTools.undefine(Post)
  end

  test "scope_by_policy routes reads through the given policy scope" do
    assert_equal Post.count, ScopedByPolicyPost.call("count_posts", actor: :someone)[:count]
    assert_equal 0, ScopedByPolicyPost.call("count_posts", actor: nil)[:count]
  end

  test "scope_by_policy raises when no policy can be found" do
    error = assert_raises(ArgumentError) do
      Class.new(ActiveAgent::SchemaTools) do
        model Post
        scope_by_policy
      end
    end

    assert_match(/No policy found for Post/, error.message)
  end

  test "scope_by_policy requires a model first" do
    assert_raises(ActiveAgent::SchemaTools::MissingModel) do
      Class.new(ActiveAgent::SchemaTools) { scope_by_policy }
    end
  end

  # --- Range filters -----------------------------------------------------
  #
  # Rails turns `where(col: {"before" => x})` into `col = NULL`, so before
  # these were supported a range filter matched nothing and reported zero.
  # An agent reads that as a truthful empty answer, which is why the silent
  # case is tested as carefully as the working one.

  class DatedPostTools < ActiveAgent::SchemaTools
    model Post
    filterable :published_at, :published
    returns :id, :title, :published_at
  end

  test "range filter compares instead of matching nothing" do
    Post.delete_all
    old = Post.create!(title: "Old", content: "body", user: @alice, published_at: 10.days.ago)
    Post.create!(title: "New", content: "body", user: @alice, published_at: 1.day.from_now)

    result = DatedPostTools.call("find_posts", published_at: { "before" => Time.current.iso8601 })

    assert_equal 1, result[:count]
    assert_equal [ old.title ], result[:results].map { |r| r[:title] }
  end

  test "count applies a range filter" do
    Post.delete_all
    Post.create!(title: "Old", content: "body", user: @alice, published_at: 10.days.ago)
    Post.create!(title: "New", content: "body", user: @alice, published_at: 1.day.from_now)

    assert_equal 1, DatedPostTools.call("count_posts", published_at: { "after" => Time.current.iso8601 })[:count]
  end

  test "range filter accepts two bounds as a window" do
    Post.delete_all
    Post.create!(title: "Way old", content: "body", user: @alice, published_at: 30.days.ago)
    inside = Post.create!(title: "Inside", content: "body", user: @alice, published_at: 5.days.ago)
    Post.create!(title: "Future", content: "body", user: @alice, published_at: 5.days.from_now)

    result = DatedPostTools.call(
      "find_posts",
      published_at: { "after" => 10.days.ago.iso8601, "before" => Time.current.iso8601 }
    )

    assert_equal 1, result[:count]
    assert_equal [ inside.title ], result[:results].map { |r| r[:title] }
  end

  test "range filter combines with an equality filter" do
    Post.delete_all
    Post.create!(title: "Old published", content: "body", user: @alice, published_at: 10.days.ago, published: true)
    Post.create!(title: "Old draft", content: "body", user: @alice, published_at: 10.days.ago, published: false)

    result = DatedPostTools.call(
      "find_posts", published: true, published_at: { "before" => Time.current.iso8601 }
    )

    assert_equal 1, result[:count]
    assert_equal [ "Old published" ], result[:results].map { |r| r[:title] }
  end

  test "rejects an unknown comparison rather than reporting zero" do
    Post.delete_all
    Post.create!(title: "Old", content: "body", user: @alice, published_at: 10.days.ago)

    result = DatedPostTools.call("find_posts", published_at: { "roughly_before" => Time.current.iso8601 })

    assert_match(/not a valid comparison/, result[:error])
    refute result.key?(:results), "must not return records when a comparison is rejected"
  end

  test "a rejected comparison never silently widens or narrows the answer" do
    Post.delete_all
    Post.create!(title: "Old", content: "body", user: @alice, published_at: 10.days.ago)

    # The failure this guards: returning {count: 0} (silently narrowed) or the
    # unfiltered set (silently widened) instead of an error.
    result = DatedPostTools.call("count_posts", published_at: { "bogus" => "2026-01-01" })

    assert result.key?(:error)
    refute result.key?(:count)
  end

  test "range filters are offered on comparable columns only" do
    properties = DatedPostTools.tool_definitions.find { |d| d[:name] == "find_posts" }
      .dig(:parameters, :properties)

    assert properties[:published_at].key?(:anyOf), "a datetime column must offer the range form"
    refute properties[:published].key?(:anyOf), "a boolean column must not offer a range form"
  end

  test "the advertised range operators are the ones accepted" do
    properties = DatedPostTools.tool_definitions.find { |d| d[:name] == "find_posts" }
      .dig(:parameters, :properties)
    advertised = properties[:published_at][:anyOf].last[:properties].keys.map(&:to_s)

    assert_equal ActiveAgent::SchemaTools::RANGE_OPERATORS.keys.sort, advertised.sort
  end
end
