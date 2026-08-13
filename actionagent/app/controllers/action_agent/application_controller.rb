# frozen_string_literal: true

module ActionAgent
  # Base controller for the ActiveAgent Dashboard.
  #
  # Handles authentication and provides helper methods for multi-tenant mode.
  class ApplicationController < ActionController::Base
    protect_from_forgery with: :exception

    before_action :authenticate_dashboard!

    # Use custom layout if configured, otherwise use engine layout
    layout -> { ActionAgent.layout || "action_agent/application" }

    helper_method :current_user, :current_owner

    # Opts an action out of the host app's authentication — for the handful
    # of endpoints that are deliberately public (the template gallery, the
    # demo sandbox). Mirrors the Rails 8 authentication generator's helper
    # so controllers read the same either side of the extraction.
    def self.allow_unauthenticated_access(**options)
      skip_before_action :authenticate_dashboard!, **options
    end

    private

    def authenticate_dashboard!
      if ActionAgent.authentication_method.nil?
        # Traces contain prompts, outputs, and error backtraces. Refuse to
        # serve them unauthenticated anywhere but a local development or
        # test environment — a staging or review-app deployment runs under
        # its own RAILS_ENV and is just as reachable as production.
        unless Rails.env.local?
          render plain: "ActiveAgent Dashboard: set ActionAgent.authentication_method " \
            "(see docs/framework/dashboard.md) to enable access in production.",
            status: :forbidden
        end
        return
      end

      result = ActionAgent.authentication_method.call(self)
      head :unauthorized unless result
    rescue StandardError => e
      Rails.logger.error("[ActionAgent] Authentication error: #{e.message}")
      head :unauthorized
    end

    # Returns the current user from the host application.
    def current_user
      return @current_user if defined?(@current_user)

      @current_user = resolve_actor(
        ActionAgent.current_user_resolver,
        ActionAgent.current_user_method,
        :current_user
      )
    end

    # Returns the current owner (account in multi-tenant, user otherwise).
    def current_owner
      # No fallback to the user in multi-tenant mode: a signed-in user with
      # no tenant owns nothing here, and quietly substituting them would
      # hand them a scope they are not part of.
      if ActionAgent.multi_tenant?
        resolve_actor(
          ActionAgent.current_account_resolver,
          ActionAgent.current_account_method,
          :current_owner
        )
      else
        current_user
      end
    end

    # Prefers the host app's lambda. A named method is only called when the
    # controller really responds to it and it isn't the accessor we are
    # already inside — configuring current_user_method = :current_user is
    # the obvious thing to write, and it would otherwise recurse forever.
    #
    # The re-entrancy guard covers the same mistake in lambda form. The
    # engine's controllers are their own base class, so the natural-looking
    # `->(c) { c.current_user }` resolves to *this* method rather than the
    # host app's, and without the guard it recurses until SystemStackError.
    # Degrading to nil turns a 500 into an unresolved owner, which now
    # scopes to nothing rather than to everything.
    def resolve_actor(resolver, method_name, own_name)
      @resolving_actors ||= {}
      return nil if @resolving_actors[own_name]

      @resolving_actors[own_name] = true
      begin
        return resolver.call(self) if resolver

        return nil if method_name.nil? || method_name.to_sym == own_name
        return nil unless respond_to?(method_name, true)

        send(method_name)
      ensure
        @resolving_actors[own_name] = false
      end
    rescue NoMethodError
      nil
    end
  end
end
