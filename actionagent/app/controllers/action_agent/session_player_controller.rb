# frozen_string_literal: true

module ActionAgent
  # Serves the document the dashboard's session player runs in. It holds the
  # replay bundle and no data: the dashboard fetches a recording's events
  # over its own API and posts them into the frame.
  #
  # The dashboard frames it with sandbox="allow-scripts allow-same-origin".
  # rrweb's Replayer rebuilds the recorded page inside an iframe of its own,
  # sandboxed to allow-same-origin only, and an iframe created inside an
  # opaque-origin document gets an opaque origin of its own, which the
  # Replayer cannot write into. A replayed page is kept inert by that inner
  # sandbox and by this response's policy, which the inner frame inherits:
  # no script but the bundle, and nothing loaded from the network.
  class SessionPlayerController < ApplicationController
    BUNDLE = "action_agent_replay.js"

    layout false

    # GET <mount>/session_player
    def show
      script_url = bundle_url
      response.headers["Content-Security-Policy"] = self.class.policy(script_url)
      response.headers["X-Frame-Options"] = "SAMEORIGIN"
      response.headers["Referrer-Policy"] = "no-referrer"
      render "action_agent/session_player/show", locals: { script_url: script_url }
    end

    # The frame's Content-Security-Policy, allowing +script_url+ as its only
    # script. A host's own policy is not merged in: the frame needs nothing
    # from it.
    # @return [String]
    def self.policy(script_url)
      [
        "default-src 'none'",
        "script-src #{script_url}",
        "style-src 'unsafe-inline'",
        "img-src data: blob:",
        "font-src data:",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-ancestors 'self'"
      ].join("; ")
    end

    private

    # The bundle's absolute URL. A CSP source naming a single file needs its
    # scheme and host, and an asset host may serve it from another origin.
    def bundle_url
      URI.join("#{request.base_url}/", helpers.asset_path(BUNDLE)).to_s
    end
  end
end
