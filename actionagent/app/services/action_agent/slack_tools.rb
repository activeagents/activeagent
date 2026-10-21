# frozen_string_literal: true

require "net/http"

module ActionAgent
  # The slack capability: reading channels and posting as the workspace's bot,
  # through the Slack Web API with the bot token the owner connected in
  # Settings -> Integrations (a ProviderKey of provider "slack"). Results and
  # errors are hashes for the model to read; the token never appears in them.
  class SlackTools
    FUNCTIONS = %w[slack_list_channels slack_read_channel slack_post_message].freeze
    API = "https://slack.com/api/"
    TIMEOUT_SECONDS = 10
    MAX_CHANNELS = 200
    MAX_MESSAGES = 50

    NOT_CONNECTED = "Slack is not connected: add a bot token (xoxb-…) in Settings -> Integrations -> Slack"

    def self.function?(name)
      FUNCTIONS.include?(name.to_s)
    end

    # The bot token +owner+ connected, or nil.
    def self.token_for(owner)
      ProviderKey.for_owner(owner).find_by(provider: "slack")&.credential.presence
    end

    # @param token [String, nil]
    def initialize(token)
      @token = token
    end

    # @return [Hash]
    def call(name, kwargs)
      return { error: "Unknown tool: #{name}" } unless self.class.function?(name)
      return { error: NOT_CONNECTED } if @token.blank?

      args = kwargs.to_h.symbolize_keys
      case name.to_s
      when "slack_list_channels" then list_channels
      when "slack_read_channel" then read_channel(**args.slice(:channel, :limit))
      when "slack_post_message" then post_message(**args.slice(:channel, :text, :thread_ts))
      end
    end

    def list_channels
      body = request("conversations.list", { types: "public_channel,private_channel", exclude_archived: true, limit: MAX_CHANNELS })
      return body if body[:error]

      channels = Array(body["channels"]).map do |channel|
        { id: channel["id"], name: channel["name"], is_member: channel["is_member"], topic: channel.dig("topic", "value").presence }.compact
      end
      { channels: channels }
    end

    def read_channel(channel:, limit: nil)
      count = (limit || 20).to_i.clamp(1, MAX_MESSAGES)
      body = request("conversations.history", { channel: channel.to_s, limit: count })
      return body if body[:error]

      messages = Array(body["messages"]).map do |message|
        { ts: message["ts"], user: message["user"] || message["bot_id"], text: message["text"], thread_ts: message["thread_ts"] }.compact
      end
      { channel: channel, messages: messages }
    end

    def post_message(channel:, text:, thread_ts: nil)
      return { error: "No text to post" } if text.to_s.strip.empty?

      body = request("chat.postMessage", { channel: channel.to_s, text: text.to_s, thread_ts: thread_ts.presence }.compact, post: true)
      return body if body[:error]

      { posted: true, channel: body["channel"], ts: body["ts"] }
    end

    private

    # Slack answers 200 with { ok: false, error: } for most failures.
    def request(method, params, post: false)
      uri = URI.join(API, method)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS) do |http|
        headers = { "Authorization" => "Bearer #{@token}", "User-Agent" => "ActiveAgents-Toolbox/1.0" }
        if post
          http.post(uri.path, params.to_json, headers.merge("Content-Type" => "application/json; charset=utf-8"))
        else
          uri.query = URI.encode_www_form(params)
          http.get(uri.request_uri, headers)
        end
      end

      body = JSON.parse(response.body.to_s)
      return { error: "Slack refused #{method}: #{body['error'] || "HTTP #{response.code}"}" } unless body["ok"]

      body
    rescue JSON::ParserError
      { error: "Slack answered #{method} with something other than JSON (HTTP #{response&.code})" }
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
      { error: "Could not reach Slack: #{e.message}" }
    end
  end
end
