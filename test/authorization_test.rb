# frozen_string_literal: true

require "test_helper"

# The actor an agent runs on behalf of, and what a refusal does.
#
# The point of the seam is that the framework never decides authorization —
# it only carries the caller and makes the two failure modes distinguishable:
# a denied tool call is something the model is told, a denied action is
# something the caller is told.
class AuthorizationTest < ActiveSupport::TestCase
  class Caller
    attr_reader :name, :allowed

    def initialize(name, allowed: [])
      @name = name
      @allowed = allowed
    end

    def may?(action) = allowed.include?(action.to_sym)
  end

  # An agent authorizing per tool, the way a host would with Pundit or
  # CanCanCan in place of `may?`.
  class RosterAgent < ActiveAgent::Base
    before_action :authorize!, only: [ :find_tickets, :delete_ticket ]

    attr_reader :audited

    def find_tickets(**filters)
      { results: [ { id: 1, for: current_user&.name } ], filters: filters }
    end

    def delete_ticket(id:)
      { deleted: id }
    end

    # No callback: the roster's open tool.
    def whoami
      { actor: current_user&.name }
    end

    private

    def authorize!
      return if current_user&.may?(action_name)

      raise ActiveAgent::NotAuthorized.new(action: action_name, actor: current_user)
    end
  end

  # A host names its own gem's error, and it is treated like ours.
  class HostErrorAgent < ActiveAgent::Base
    class AccessDenied < StandardError; end

    denies_with AccessDenied

    before_action :check

    def read_records = { ok: true }

    private

    def check = raise(AccessDenied, "not your record")
  end

  # The same error, mapped through rescue_from instead: ActiveSupport answers
  # a handled exception with the exception, so a tool call would otherwise
  # hand the model an exception object as its result.
  class RescuedHostErrorAgent < ActiveAgent::Base
    denies_with HostErrorAgent::AccessDenied
    rescue_from HostErrorAgent::AccessDenied, with: :noted

    before_action :check

    def read_records = { ok: true }

    private

    def check = raise(HostErrorAgent::AccessDenied, "not your record")

    def noted(exception) = exception
  end

  def tool_call(agent_class, action, actor: nil, **kwargs)
    agent = agent_class.new
    agent.current_user = actor
    agent.tools_function.call(action, **kwargs)
  end

  test "the actor reaches the action and its callbacks" do
    reader = Caller.new("Reader", allowed: [ :find_tickets ])

    result = tool_call(RosterAgent, :find_tickets, actor: reader, status: "open")

    assert_equal [ { id: 1, for: "Reader" } ], result[:results]
    assert_equal({ status: "open" }, result[:filters])
  end

  test "a refused tool call is reported to the model rather than raised" do
    reader = Caller.new("Reader", allowed: [ :find_tickets ])

    result = tool_call(RosterAgent, :delete_ticket, actor: reader, id: 7)

    # The model has to be able to say "I'm not allowed to do that" — a raise
    # would kill the run, and an empty result would read as a fact.
    assert_equal "the current caller is not allowed to call `delete_ticket`", result[:error]
  end

  test "an unattributed caller is refused rather than treated as permitted" do
    result = tool_call(RosterAgent, :find_tickets)

    assert_equal "an unauthenticated caller is not allowed to call `find_tickets`", result[:error]
  end

  test "a tool with no authorization callback still runs, and sees the actor" do
    assert_equal({ actor: "Reader" }, tool_call(RosterAgent, :whoami, actor: Caller.new("Reader")))
  end

  test "a refused action is raised to the caller instead of answered" do
    agent = RosterAgent.new
    agent.current_user = Caller.new("Reader")

    # Not a tool call: whoever asked for this action gets an error, not an
    # answer that quietly covers less ground than it appears to.
    error = assert_raises(ActiveAgent::NotAuthorized) { agent.process(:find_tickets) }
    assert_equal "find_tickets", error.action.to_s
  end

  test "an error a host names with denies_with refuses like ours" do
    assert_equal({ error: "not your record" }, tool_call(HostErrorAgent, :read_records))
  end

  test "a refusal a host also rescues still reaches the model as an error" do
    assert_equal({ error: "not your record" }, tool_call(RescuedHostErrorAgent, :read_records))
  end

  test "naming an error is per agent class and never widens another's" do
    assert_includes HostErrorAgent.authorization_errors, HostErrorAgent::AccessDenied
    assert_equal [ ActiveAgent::NotAuthorized ], RosterAgent.authorization_errors
  end

  test "as() carries the actor onto the generation, and chains with with()" do
    reader = Caller.new("Reader", allowed: [ :find_tickets ])

    generation = RosterAgent.as(reader).find_tickets
    assert_equal reader, generation.actor

    chained = RosterAgent.as(reader).with(locale: :en).find_tickets
    assert_equal reader, chained.actor
    assert_equal({ locale: :en }, chained.instance_variable_get(:@params))

    # Either order, same result.
    assert_equal reader, RosterAgent.with(locale: :en).as(reader).find_tickets.actor
  end

  test "the actor is not reachable through params" do
    agent = RosterAgent.new
    agent.params = { current_user: Caller.new("Impostor", allowed: [ :delete_ticket ]) }

    # Whatever a caller puts in params, the actor is only what was assigned
    # out of band — params are what a generation is about, not who it is for.
    assert_nil agent.current_user
    assert_equal "an unauthenticated caller is not allowed to call `delete_ticket`",
      agent.tools_function.call(:delete_ticket, id: 7)[:error]
  end
end
