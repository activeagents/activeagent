# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module ActionAgent
  # Used to give a client that runs other people's code, such as a Claude
  # Code turn, the sandbox's browser without its master token: the sidecar
  # mints a client token for /mcp only (POST /tokens), labelled with who it
  # is for, and the token is revoked once the turn ends (DELETE /tokens/:id).
  # Its shell commands inherit what Claude Code was given, so a token they
  # could read must be worthless once the turn is over.
  class BrowserClientToken
    TIMEOUT = 5

    class Error < StandardError; end

    attr_reader :id, :token, :mcp_url

    # Mints a token for +sandbox+'s running browser.
    #
    # @param sandbox [SandboxSession]
    # @param label [String] what the live view calls the client
    # @return [BrowserClientToken]
    # @raise [Error] when the browser is not running or refuses
    def self.mint(sandbox, label:)
      raise Error, "The sandbox's browser is not running" unless sandbox.browser_running? && sandbox.browser_token.present?

      mcp_url = URI(sandbox.browser_mcp_url)
      body = request(Net::HTTP::Post, tokens_uri(mcp_url), sandbox.browser_token, JSON.generate(label: label))
      new(id: body.fetch("id"), token: body.fetch("token"), mcp_url: mcp_url.to_s, sandbox: sandbox)
    rescue KeyError, JSON::ParserError
      raise Error, "The browser answered a token request without one"
    end

    def initialize(id:, token:, mcp_url:, sandbox:)
      @id = id
      @token = token
      @mcp_url = mcp_url
      @sandbox = sandbox
    end

    # Revokes the token. A browser that stopped meanwhile took its tokens
    # with it, so a failure here is only logged.
    def revoke!
      self.class.request(Net::HTTP::Delete, self.class.tokens_uri(URI(@mcp_url), @id), @sandbox.browser_token)
      true
    rescue Error, SystemCallError, IOError, Timeout::Error, URI::Error => e
      Rails.logger.info("[ActionAgent] browser client token #{@id} not revoked: #{e.message}")
      false
    end

    # The Claude Code --mcp-config document reaching the browser as the
    # "browser" server with this token.
    def mcp_config
      { mcpServers: { browser: { type: "http", url: mcp_url, headers: { "Authorization" => "Bearer #{token}" } } } }
    end

    class << self
      def tokens_uri(mcp_url, id = nil)
        uri = mcp_url.dup
        uri.path = id ? "/tokens/#{id}" : "/tokens"
        uri.query = nil
        uri
      end

      # @return [Hash] the parsed body
      def request(klass, uri, master_token, body = nil)
        raise Error, "Only a loopback browser is reached this way" unless %w[127.0.0.1 localhost ::1 [::1]].include?(uri.host)

        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = TIMEOUT
        http.read_timeout = TIMEOUT
        request = klass.new(uri)
        request["Authorization"] = "Bearer #{master_token}"
        request["Content-Type"] = "application/json"
        request.body = body if body
        response = http.request(request)
        raise Error, "The browser answered HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        response.body.to_s.empty? ? {} : JSON.parse(response.body)
      end
    end
  end
end
