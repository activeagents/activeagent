# frozen_string_literal: true

require "test_helper"
require "json"

# The seams a host app extends the engine's classes through —
# ActionAgent.model_concerns and ActionAgent.controller_concerns — and the
# single model hierarchy the first one relies on.
#
# The model tests reopen ActionAgent::ApplicationRecord with `load`, which
# re-runs its class body against the configuration of the moment; the body is
# idempotent, so the process is left as it was apart from the module included.
# Reopening ApplicationController the same way is not harmless: its callback
# macros would re-run and reorder every loaded subclass's chain. What a
# controller concern does on the classes' first load is therefore read from a
# child process that boots the dummy app with both lists configured
# (support/first_load_script.rb).
class HostIntegrationTest < ActiveSupport::TestCase
  # The shape of a host's connection-switching concern: class-level behaviour
  # every model must carry.
  module ConnectionSwitching
    extend ActiveSupport::Concern

    class_methods do
      def pinned_connection? = true
    end
  end

  MODEL_FILE = ActionAgent::Engine.root.join("app/models/action_agent/application_record.rb").to_s
  FIRST_LOAD_SCRIPT = File.expand_path("support/first_load_script.rb", __dir__)

  setup do
    @model_concerns = ActionAgent.model_concerns
    @controller_concerns = ActionAgent.controller_concerns
  end

  teardown do
    ActionAgent.model_concerns = @model_concerns
    ActionAgent.controller_concerns = @controller_concerns
  end

  test "TelemetryTrace is an engine model like the others" do
    assert_operator ActionAgent::TelemetryTrace, :<, ActionAgent::ApplicationRecord
    assert_equal "active_agent_telemetry_traces", ActionAgent::TelemetryTrace.table_name
    assert_respond_to ActionAgent::TelemetryTrace, :postgres?
    assert_nil ActionAgent::TelemetryTrace.owner_association
  end

  test "every persisted engine model inherits ApplicationRecord" do
    Rails.autoloaders.main.eager_load_dir(ActionAgent::Engine.root.join("app/models").to_s)
    engine_models = ActiveRecord::Base.descendants.select { |model| model.name.to_s.start_with?("ActionAgent::") }
    strays = engine_models.reject { |model| model <= ActionAgent::ApplicationRecord }

    assert_includes engine_models, ActionAgent::TelemetryTrace
    assert_includes engine_models, ActionAgent::Agent
    assert_empty strays, "outside the hierarchy model_concerns extends"
  end

  test "model concerns are included as ApplicationRecord loads and reach every model" do
    ActionAgent.model_concerns = [ "HostIntegrationTest::ConnectionSwitching" ]
    reload_class(MODEL_FILE)

    assert ActionAgent::ApplicationRecord.include?(ConnectionSwitching)
    assert ActionAgent::Agent.pinned_connection?
    assert ActionAgent::TelemetryTrace.pinned_connection?
  end

  test "a model concern may be given as a Module" do
    concern = Module.new
    ActionAgent.model_concerns = [ concern ]
    reload_class(MODEL_FILE)

    assert ActionAgent::ApplicationRecord.include?(concern)
  end

  test "a model concern that resolves to nothing fails as the class loads, naming it" do
    ActionAgent.model_concerns = [ "HostIntegrationTest::NoSuchConcern" ]

    error = assert_raises(NameError) { reload_class(MODEL_FILE) }
    assert_includes error.message, "NoSuchConcern"
  end

  test "on first load, a model concern's included block sees the abstract base with no table name" do
    assert_equal [ [ true, nil ] ], first_load.fetch("included_saw")
  end

  test "on first load, a model concern's inherited hook sees every model's table, the trace table among them" do
    assert_includes first_load.fetch("registered_tables"), "active_agent_telemetry_traces"
    assert_includes first_load.fetch("registered_tables"), "active_agent_agents"
    assert_equal [ true, true ], first_load.fetch("models_pinned")
  end

  test "on first load, a controller concern's before_action precedes the dashboard's authentication" do
    %w[application_controller_filters base_controller_filters].each do |chain|
      filters = first_load.fetch(chain)

      assert_operator filters.index("note_host_session"), :<, filters.index("authenticate_dashboard!"), chain
    end
  end

  test "on first load, a dashboard controller's own callback skips still hold" do
    assert_not_includes first_load.fetch("base_controller_filters"), "verify_authenticity_token"
    assert_not_includes first_load.fetch("mcp_controller_filters"), "authenticate_dashboard!"
  end

  test "controller concerns do not reach the bearer-token ingest endpoint" do
    assert_equal false, first_load.fetch("traces_controller_session_aware")
  end

  test "a resolver reaches the concern's session reader while the engine's current_user stays in charge" do
    assert_equal "session_user", first_load.fetch("dashboard_current_user")
    assert_equal false, first_load.fetch("dashboard_public_current_user")
  end

  test "reset! clears both concern lists" do
    ActionAgent.model_concerns = [ Module.new ]
    ActionAgent.controller_concerns = [ Module.new ]

    ActionAgent.reset!

    assert_equal [], ActionAgent.model_concerns
    assert_equal [], ActionAgent.controller_concerns
  end

  test "assigning base_controller_class warns and points at controller_concerns" do
    previous = ActionAgent.base_controller_class

    assert_deprecated(/controller_concerns/, ActionAgent.deprecator) do
      ActionAgent.base_controller_class = "AdminController"
    end
    assert_equal "AdminController", ActionAgent.base_controller_class
  ensure
    ActionAgent.instance_variable_set(:@base_controller_class, previous)
  end

  private

  # Re-evaluates a class body the way a code reload does, so the includes the
  # configuration produces at load time are observable in a booted app.
  def reload_class(file)
    load file
  end

  # What the engine's classes looked like on their first load with both
  # concern lists configured, from one boot of the dummy app shared by every
  # test that reads it.
  def first_load
    self.class.first_load
  end

  def self.first_load
    @first_load ||= begin
      output = IO.popen([ RbConfig.ruby, FIRST_LOAD_SCRIPT ], err: %i[child out], &:read)
      JSON.parse(output.lines.last.to_s)
    rescue JSON::ParserError
      raise "the first-load boot did not report: #{output}"
    end
  end
end
