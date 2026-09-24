# frozen_string_literal: true

# Boots the dummy app with a model concern and a controller concern configured
# the way a host's initializer configures them, then reports what the engine's
# classes looked like on their first load. HostIntegrationTest runs it out of
# process, because the test process has loaded those classes long before any
# test can configure them.
ENV["RAILS_ENV"] = "test"
require File.expand_path("../../../test/dummy/config/environment", __dir__)
require "json"

included_saw = []
registered_tables = []

# The shape of a host's connection-switching concern: an included block that
# reads the base's table name, and an inherited hook that registers every
# subclass's.
model_concern = Module.new do
  extend ActiveSupport::Concern

  included { included_saw << [ abstract_class?, table_name ] }

  class_methods do
    define_method(:inherited) do |subclass|
      super(subclass)
      registered_tables << subclass.table_name
    end

    def pinned_connection? = true
  end
end

# The shape of a host's session concern: an included block with class-level
# DSL and a before_action, a public current_user of its own, and the session
# reader the host's resolvers call.
controller_concern = Module.new do
  extend ActiveSupport::Concern

  included do
    class_attribute :host_session_aware, default: true
    before_action :note_host_session
  end

  def current_user = :host_user

  def user_from_session = :session_user

  private

  def note_host_session; end
end

ActionAgent.model_concerns = [ model_concern ]
ActionAgent.controller_concerns = [ controller_concern ]
ActionAgent.current_user_resolver = ->(controller) { controller.send(:user_from_session) }

models = [ ActionAgent::Agent, ActionAgent::TelemetryTrace ]
filters = ->(controller) { controller._process_action_callbacks.map { |callback| callback.filter.to_s } }

puts JSON.generate(
  included_saw: included_saw,
  registered_tables: registered_tables,
  models_pinned: models.map(&:pinned_connection?),
  application_controller_filters: filters.call(ActionAgent::ApplicationController),
  base_controller_filters: filters.call(ActionAgent::Api::BaseController),
  mcp_controller_filters: filters.call(ActionAgent::Api::MCPController),
  traces_controller_session_aware: ActionAgent::Api::TracesController.respond_to?(:host_session_aware),
  dashboard_public_current_user: ActionAgent::DashboardController.public_method_defined?(:current_user),
  dashboard_current_user: ActionAgent::DashboardController.new.send(:current_user).to_s
)
