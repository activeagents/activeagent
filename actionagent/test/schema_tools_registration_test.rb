# frozen_string_literal: true

require "test_helper"

# Covers the seam that lets a host offer ActiveAgent::SchemaTools classes to
# the dashboard: selectable in the editor, dispatched at execution, and
# attached by naming convention.
class SchemaToolsRegistrationTest < ActiveSupport::TestCase
  class FakeTools
    def self.model = Struct.new(:name).new("Reservation")
    def self.tool_names = %w[find_reservations count_reservations]
    def self.tool?(name) = tool_names.include?(name.to_s)

    def self.tool_definitions
      tool_names.map { |n| { name: n, description: "#{n} desc", parameters: { type: "object" } } }
    end

    def self.call(name, actor: nil, **arguments)
      { called: name, actor: actor, arguments: arguments }
    end
  end

  setup do
    @previous = ActionAgent.schema_tools
    ActionAgent.schema_tools = [ FakeTools ]
  end

  teardown { ActionAgent.schema_tools = @previous }

  test "discovery is skipped when tools are declared explicitly" do
    ActionAgent.schema_tools = [ FakeTools ]

    assert_equal [ FakeTools ], ActionAgent.schema_tool_classes
  end

  test "an anonymous class is usable when declared but never discovered" do
    anonymous = Class.new(FakeTools)

    ActionAgent.schema_tools = [ anonymous ]
    assert_equal [ anonymous ], ActionAgent.schema_tool_classes

    # Left to discovery it is skipped: a runtime-built class cannot supersede
    # itself, so it would accumulate across reloads.
    ActionAgent.schema_tools = nil
    assert_not_includes ActionAgent.schema_tool_classes, anonymous
  end

  test "a runtime definition is discovered once, and a redefinition supersedes it" do
    ActionAgent.schema_tools = nil
    defined = ActiveAgent::SchemaTools.define(Post, filterable: %i[published], returns: %i[id title])

    assert_includes ActionAgent.schema_tool_classes, defined
    assert_equal 1, ActionAgent.schema_tool_classes.count { |klass| klass.model.name == "Post" }

    again = ActiveAgent::SchemaTools.define(Post, filterable: %i[published], returns: %i[id])

    assert_includes ActionAgent.schema_tool_classes, again
    assert_not_includes ActionAgent.schema_tool_classes, defined, "a superseded class must not be offered beside its replacement"
    assert_equal 1, ActionAgent.schema_tool_classes.count { |klass| klass.model.name == "Post" }
    assert_equal again.tool_names, ActionAgent::Agent.new(name: "PostAgent").tap(&:valid?).tools
  ensure
    ActiveAgent::SchemaTools.undefine(Post)
  end

  test "a runtime definition supersedes a file-defined class for the same model" do
    ActionAgent.schema_tools = nil
    previous_path = ActionAgent.schema_tools_path
    # File discovery scans descendants only when the directory exists; the
    # dummy app has none, so point discovery at an empty one for this test.
    ActionAgent.schema_tools_path = Dir.mktmpdir
    file_defined = Class.new(ActiveAgent::SchemaTools) { model Post; returns :id }
    file_defined.define_singleton_method(:name) { "FileBackedPostTools" }
    assert_includes ActionAgent.schema_tool_classes, file_defined

    runtime = ActiveAgent::SchemaTools.define(Post, returns: %i[id title])

    assert_includes ActionAgent.schema_tool_classes, runtime
    assert_not_includes ActionAgent.schema_tool_classes, file_defined
  ensure
    ActiveAgent::SchemaTools.undefine(Post)
    ActionAgent.schema_tools_path = previous_path
  end

  test "runtime definitions are offered even when file discovery is switched off" do
    ActionAgent.schema_tools = nil
    previous_path = ActionAgent.schema_tools_path
    ActionAgent.schema_tools_path = nil
    runtime = ActiveAgent::SchemaTools.define(Post, returns: %i[id])

    assert_equal [ runtime ], ActionAgent.schema_tool_classes
  ensure
    ActiveAgent::SchemaTools.undefine(Post)
    ActionAgent.schema_tools_path = previous_path
  end

  test "an explicit declaration excludes the registry unless it names it" do
    runtime = ActiveAgent::SchemaTools.define(Post, returns: %i[id])

    ActionAgent.schema_tools = [ FakeTools ]
    assert_equal [ FakeTools ], ActionAgent.schema_tool_classes

    ActionAgent.schema_tools = [ FakeTools, runtime ]
    assert_equal [ FakeTools, runtime ], ActionAgent.schema_tool_classes
  ensure
    ActiveAgent::SchemaTools.undefine(Post)
  end

  test "discovery is disabled by a blank path" do
    ActionAgent.schema_tools = nil
    previous_path = ActionAgent.schema_tools_path
    ActionAgent.schema_tools_path = nil

    assert_empty ActionAgent.schema_tool_classes
  ensure
    ActionAgent.schema_tools_path = previous_path
  end

  test "declared classes resolve, including from a class-name string" do
    assert_equal [ FakeTools ], ActionAgent.schema_tool_classes

    ActionAgent.schema_tools = [ "SchemaToolsRegistrationTest::FakeTools" ]
    assert_equal [ FakeTools ], ActionAgent.schema_tool_classes
  end

  test "a name that does not resolve is skipped rather than raising" do
    ActionAgent.schema_tools = [ "NoSuchToolsClass", FakeTools ]

    assert_equal [ FakeTools ], ActionAgent.schema_tool_classes
  end

  test "generated tools join the editor palette without displacing built-ins" do
    available = ActionAgent::Agent.available_tools

    assert_includes available, "find_reservations"
    ActionAgent::Agent::AVAILABLE_TOOLS.each { |builtin| assert_includes available, builtin }
  end

  test "the toolbox recognises and dispatches a generated tool" do
    assert ActionAgent::AgentToolbox.function?("find_reservations")
    assert_equal [ "find_reservations" ],
      ActionAgent::AgentToolbox.definitions_for(%w[find_reservations]).map { |d| d[:name] }

    result = ActionAgent::AgentToolbox.call("find_reservations", actor: :someone, status: "held")
    assert_equal "find_reservations", result[:called]
    assert_equal :someone, result[:actor]
    assert_equal({ status: "held" }, result[:arguments])
  end

  test "a nil actor is passed through rather than widened" do
    result = ActionAgent::AgentToolbox.call("find_reservations")

    assert_nil result[:actor]
  end

  test "an unknown tool is still unknown" do
    assert_not ActionAgent::AgentToolbox.function?("find_nothing")
    assert_equal "Unknown tool: find_nothing", ActionAgent::AgentToolbox.call("find_nothing")[:error]
  end

  test "a new agent named after the model starts with its tools" do
    agent = ActionAgent::Agent.new(name: "ReservationAgent")
    agent.valid?

    assert_equal FakeTools.tool_names, agent.tools
  end

  test "the convention tolerates spacing and casing, and reads agent_class_name" do
    %w[ReservationAgent].each do |name|
      assert_equal FakeTools.tool_names, ActionAgent::Agent.new(name: name).tap(&:valid?).tools
    end

    assert_equal FakeTools.tool_names,
      ActionAgent::Agent.new(name: "Reservation Agent").tap(&:valid?).tools
    assert_equal FakeTools.tool_names,
      ActionAgent::Agent.new(name: "Anything", agent_class_name: "ReservationAgent").tap(&:valid?).tools
  end

  test "the convention is a default, never an overwrite or a restriction" do
    chosen = ActionAgent::Agent.new(name: "ReservationAgent", tools: [ "fetch" ])
    chosen.valid?
    assert_equal [ "fetch" ], chosen.tools

    unrelated = ActionAgent::Agent.new(name: "SomethingElse")
    unrelated.valid?
    assert_empty unrelated.tools
  end
end
