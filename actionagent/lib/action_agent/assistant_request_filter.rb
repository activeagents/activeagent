# frozen_string_literal: true

module ActionAgent
  # Runs before Rails' request logger, including for requests later rejected by
  # authentication, consent or CSRF. Match the endpoint under any engine mount;
  # leave the host application's unrelated message/history parameters alone.
  class AssistantRequestFilter
    PATH = %r{/api/dashboard_assistant(?:\.[^/]+)?/?\z}
    PARAMETERS = [ /\Amessage\z/i, /\Ahistory\z/i ].freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      if PATH.match?(env["PATH_INFO"].to_s)
        env["action_dispatch.parameter_filter"] = Array(env["action_dispatch.parameter_filter"]) + PARAMETERS
      end
      @app.call(env)
    end
  end
end
