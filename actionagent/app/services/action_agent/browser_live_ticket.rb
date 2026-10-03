# frozen_string_literal: true

require "base64"
require "json"
require "openssl"

module ActionAgent
  # Used to issue the tickets that let a dashboard viewer into a sandbox
  # browser's live view. The viewer's page sends the ticket as the first
  # message on the live view's WebSocket, and the browser sidecar checks it
  # (browser-sidecar/lib/live-ticket.mjs), so a ticket never travels in a URL.
  #
  # A ticket is base64url JSON claims, a dot, and the base64url HMAC-SHA256
  # of that first part. The key is the HMAC-SHA256 of CONTEXT under the
  # browser's token, which the sidecar was given on stdin when it started:
  # a ticket opens only the browser it was issued for, and only until that
  # browser stops. The sidecar accepts each ticket once, within LIFETIME.
  #
  # Claims:
  #   v     1
  #   sid   the sandbox session
  #   sub   the user it was issued to, as a String, or nil without one
  #   name  their name, shown to other viewers ("held by Ada"), or nil
  #   mode  "view" to watch, "control" to also take over
  #   iat   when it was issued, in epoch seconds
  #   exp   when it expires, in epoch seconds
  #   jti   its unique id
  class BrowserLiveTicket
    CONTEXT = "activeagents/browser-live-ticket/v1"
    MODES = %w[view control].freeze
    # The sidecar refuses a ticket issued for longer than 60 seconds.
    LIFETIME = 30.seconds
    MAX_NAME_LENGTH = 80

    # Returns { ticket:, mode:, expires_at: } for +sandbox+'s running browser.
    #
    # @param user [Object, nil] the viewer, whose id and name the ticket carries
    # @param mode [String] one of MODES
    # @raise [ArgumentError] for an unknown mode, or a sandbox whose browser
    #   has no token
    def self.issue(sandbox, user:, mode:, now: Time.current, jti: SecureRandom.urlsafe_base64(24))
      raise ArgumentError, "mode must be one of #{MODES.join(', ')}" unless MODES.include?(mode)
      raise ArgumentError, "The sandbox's browser has no token" if sandbox.browser_token.blank?

      issued_at = now.to_i
      claims = {
        v: 1,
        sid: sandbox.session_id,
        sub: user&.id&.to_s,
        name: display_name(user),
        mode: mode,
        iat: issued_at,
        exp: issued_at + LIFETIME.to_i,
        jti: jti
      }
      { ticket: sign(sandbox.browser_token, claims), mode: mode, expires_at: Time.zone.at(claims[:exp]) }
    end

    # The ticket for +claims+, signed with the key derived from +token+.
    def self.sign(token, claims)
      payload = Base64.urlsafe_encode64(JSON.generate(claims), padding: false)
      signature = OpenSSL::HMAC.digest("SHA256", key(token), payload)
      "#{payload}.#{Base64.urlsafe_encode64(signature, padding: false)}"
    end

    def self.key(token)
      OpenSSL::HMAC.digest("SHA256", token, CONTEXT)
    end

    def self.display_name(user)
      return nil unless user

      name = user.try(:display_name).presence || user.try(:name).presence || user.try(:email_address).presence || user.try(:email).presence
      name&.to_s&.truncate(MAX_NAME_LENGTH)
    end
    private_class_method :key, :display_name
  end
end
