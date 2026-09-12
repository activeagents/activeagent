# frozen_string_literal: true

module ActiveAgent
  # Raised when an agent refuses a call on the current caller's behalf.
  #
  # Hosts usually raise their authorization gem's own error instead
  # (+Pundit::NotAuthorizedError+, +CanCan::AccessDenied+) and name it with
  # {Authorization::ClassMethods#denies_with}; this exists so an agent that
  # has no gem still has something to raise, and so the framework has one
  # class to describe a refusal with.
  class NotAuthorized < StandardError
    # @return [Symbol, String, nil] the action or tool that was refused
    attr_reader :action
    # @return [Object, nil] the caller the refusal was decided against
    attr_reader :actor

    def initialize(message = nil, action: nil, actor: nil)
      @action = action
      @actor = actor
      super(message || default_message)
    end

    private

    def default_message
      who = actor.nil? ? "an unauthenticated caller" : "the current caller"
      what = action ? "`#{action}`" : "this agent"
      "#{who} is not allowed to call #{what}"
    end
  end

  # Carries the caller an agent runs on behalf of, so an agent's callbacks can
  # authorize with whatever the host app already uses.
  #
  # An agent reached over MCP, from a dashboard run, or from a controller is
  # acting *for someone*. Without that someone, an authorization gem has
  # nothing to decide against: a Pundit scope handed +nil+ correctly resolves
  # to the empty set, so a perfectly wired agent answers "there are no
  # tickets" instead of refusing — a wrong answer that reads like a true one.
  #
  # == The seam
  #
  # {#current_user} is assigned by whatever authenticated the call and is
  # readable from every callback and action:
  #
  #   class TicketAgent < ApplicationAgent
  #     before_action :authorize_tickets!
  #
  #     def find_tickets(**filters)
  #       TicketTools.call("find_tickets", actor: current_user, **filters)
  #     end
  #
  #     private
  #
  #     def authorize_tickets!
  #       raise ActiveAgent::NotAuthorized.new(action: action_name, actor: current_user) unless
  #         TicketPolicy.new(current_user, Ticket).index?
  #     end
  #   end
  #
  #   TicketAgent.as(current_user).find_tickets.generate_now
  #
  # Any gem works, because the framework never interprets the actor — Pundit's
  # +authorize+/+policy_scope+, CanCanCan's +can?+, Action Policy's
  # +authorize!+, or a plain predicate. +before_action+ is the same
  # +AbstractController+ chain a controller uses, including +only:+/+except:+,
  # so a roster can be authorized tool by tool.
  #
  # == It is never model input
  #
  # The actor is an attribute of the run, set out of band by the caller. It is
  # deliberately not part of +params+ and not a tool argument: everything a
  # model emits is attacker-reachable through the documents it reads, and an
  # actor a model can name is not an authorization boundary. Assigning it is
  # the caller's job, once, before the generation starts.
  #
  # == What a refusal does
  #
  # A refusal inside a *tool call* is returned to the model as an error result
  # ({ error: ... }), so it can tell the user it is not allowed to look rather
  # than dying mid-run or, worse, reporting an empty result set as fact. A
  # refusal anywhere else — the action the caller asked for — is raised, so
  # the MCP client or controller that asked gets an error instead of an
  # answer that silently covers less ground than it appears to.
  #
  # {ClassMethods#denies_with} is how a gem's own error joins that rule:
  #
  #   class ApplicationAgent < ActiveAgent::Base
  #     denies_with Pundit::NotAuthorizedError
  #   end
  module Authorization
    extend ActiveSupport::Concern

    included do
      # The caller this generation runs on behalf of, or nil when it runs
      # unattributed. Whatever the host uses as an actor: a User, an API
      # key's owner, a service account.
      attr_accessor :current_user

      # Exception classes that mean "the caller may not do this". Declared
      # rather than guessed: only the host knows which of its errors are a
      # refusal and which are a bug.
      class_attribute :authorization_errors, instance_writer: false,
        default: [ ActiveAgent::NotAuthorized ].freeze
    end

    class_methods do
      # Treats +classes+ as refusals, so raising one inside a tool call
      # reports to the model instead of ending the run.
      #
      # @param classes [Array<Class>] exception classes from an authorization gem
      # @return [Array<Class>] every class now treated as a refusal
      #
      # @example
      #   denies_with Pundit::NotAuthorizedError, CanCan::AccessDenied
      def denies_with(*classes)
        self.authorization_errors = (authorization_errors | classes.flatten).freeze
      end

      # Runs the agent on behalf of +actor+.
      #
      # @param actor [Object, nil] the caller, or nil to run unattributed
      # @return [ActiveAgent::Parameterized::Agent] a proxy carrying the actor
      #
      # @example
      #   SupportAgent.as(current_user).answer(question).generate_now
      #
      # @example With parameters
      #   SupportAgent.as(current_user).with(locale: :en).answer(question)
      def as(actor)
        ActiveAgent::Parameterized::Agent.new(self, {}, actor: actor)
      end
    end

    # Whether a refusal right now would be reported to the model rather than
    # raised to the caller.
    # @return [Boolean]
    def tool_call?
      @_active_agent_tool_call ||= false
    end

    # Marks the block as a tool call, so a refusal inside it becomes a result
    # the model can read. Nested calls keep the outer marking.
    # @api private
    def with_tool_call
      previous = @_active_agent_tool_call
      @_active_agent_tool_call = true

      result = yield
      # A host's own rescue_from handler runs inside `process`, and
      # ActiveSupport::Rescuable answers with the exception itself — so a
      # refusal arrives either raised or returned, and both mean the same
      # thing here.
      refusal?(result) ? refused(result) : result
    rescue *authorization_errors => exception
      refused(exception)
    ensure
      @_active_agent_tool_call = previous
    end

    private

    def refusal?(value)
      value.is_a?(Exception) && authorization_errors.any? { |klass| value.is_a?(klass) }
    end

    def refused(exception)
      logger&.info("[#{self.class.name}] refused #{action_name}: #{exception.message}")
      { error: exception.message }
    end
  end
end
