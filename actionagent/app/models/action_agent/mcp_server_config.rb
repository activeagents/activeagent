# frozen_string_literal: true

module ActionAgent
  # A remote MCP server a dashboard user added on the MCP Services page, so
  # their agents can call a server neither the built-in catalog nor the host
  # app's ActionAgent.mcp_catalog lists: their own app's MCP endpoint, say.
  #
  # An agent enables one under its key, "custom:<id>", the way it enables a
  # catalog server under its slug. MCPToolDispatcher resolves the key among
  # the agent's owner's configurations only (.server_entry), so naming
  # another owner's id reaches nothing, and an agent run or a scenario
  # evaluation run calls its tools like a catalog server's.
  #
  # The server is reached over Streamable HTTP at +url+. Request headers
  # (an Authorization header, an API key header) are kept in +secret_headers+,
  # a JSON object encrypted at rest with the provider keys. Their values are
  # never rendered back to the browser: #header_hints names each header with
  # a masked value, and #assign_headers keeps a header's stored value when
  # an update leaves it blank.
  #
  # The URL may not reach a non-public address unless the host app sets
  # ActionAgent.allow_private_mcp_hosts (see MCPHostGuard). A disabled
  # configuration stays listed but is not dispatched to.
  class MCPServerConfig < ApplicationRecord
    include Ownable
    owned_by :account, :user

    # The key an agent's mcp_servers names a configuration by.
    KEY_PREFIX = "custom:"
    KEY_PATTERN = /\Acustom:(\d+)\z/

    MAX_HEADERS = 20
    MAX_HEADER_VALUE_LENGTH = 4096
    # An HTTP header field name (RFC 9110 token).
    HEADER_NAME = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
    # Headers MCPClient sets itself, which a configuration cannot replace
    # without breaking the protocol it speaks.
    RESERVED_HEADERS = %w[accept content-type content-length host mcp-session-id user-agent connection transfer-encoding].freeze
    # How many tool names a test records.
    MAX_TOOL_NAMES = 500

    TEST_OK = "ok"
    TEST_FAILED = "failed"

    encrypts :secret_headers if ActionAgent.encrypt_credentials

    validates :name, presence: true, length: { maximum: 100 }
    validates :url, presence: true, length: { maximum: 2048 }
    validate :url_is_reachable_address
    validate :headers_are_valid

    scope :enabled, -> { where(enabled: true) }

    class << self
      # Whether +key+ names a configuration ("custom:<id>").
      def key?(key)
        KEY_PATTERN.match?(key.to_s.strip)
      end

      # The configuration +key+ names, looked up among +owner+'s only, or nil.
      #
      # @param key [String]
      # @param owner [Object, nil] the agent's owner
      # @return [MCPServerConfig, nil]
      def find_by_key(key, owner:)
        id = key.to_s.strip[KEY_PATTERN, 1] or return nil

        for_owner(owner).find_by(id: id)
      end

      # The connection MCPToolDispatcher calls, headers included, for the
      # configuration +key+ names among +owner+'s. Nil when there is none or
      # it is disabled.
      #
      # @return [Hash, nil]
      def server_entry(key, owner:)
        find_by_key(key, owner: owner)&.server_entry
      end

      # The configurations in +scope+ (a relation already scoped to an owner)
      # as MCP server listings: the catalog entry shape MCPCatalog serves,
      # without headers. ToolDiscovery and AgentToolRoster list them beside
      # the catalog, as they list checkout runtimes.
      #
      # @return [Array<Hash>]
      def listings(scope)
        scope.order(:name, :id).map(&:listing)
      end
    end

    def server_key
      "#{KEY_PREFIX}#{id}"
    end

    # The request headers, name => value. Empty when none are set or the
    # stored value is not a JSON object.
    #
    # @return [Hash{String => String}]
    def headers
      parsed = JSON.parse(secret_headers.presence || "{}")
      parsed.is_a?(Hash) ? parsed.transform_values(&:to_s) : {}
    rescue JSON::ParserError
      {}
    end

    def headers=(value)
      self.secret_headers = value.to_h.transform_keys(&:to_s).transform_values(&:to_s).to_json
    end

    # Replaces the headers with +submitted+, a list of { name, value } pairs.
    # A header submitted with a blank value keeps the value stored under the
    # same name (compared without case); a header left out is removed. A new
    # header with a blank value is kept blank, so validation refuses it.
    #
    # @param submitted [Array<Hash>]
    def assign_headers(submitted)
      stored = headers.transform_keys(&:downcase)

      self.headers = Array(submitted).each_with_object({}) do |header, kept|
        header = header.to_h.stringify_keys
        name = header["name"].to_s.strip
        next if name.blank?

        value = header["value"].to_s
        kept[name] = value.strip.empty? ? stored[name.downcase].to_s : value
      end
    end

    # Each header's name with a masked value, for the browser.
    #
    # @return [Array<Hash>] +{ name:, hint: }+
    def header_hints
      headers.map { |name, value| { name: name, hint: mask(value) } }
    end

    # Every header value, for scrubbing from recorded output.
    def secret_values
      headers.values.reject(&:blank?)
    end

    # The connection MCPToolDispatcher calls, headers included, or nil when
    # the configuration is disabled. Never serialized to the browser.
    #
    # @return [Hash, nil]
    def server_entry
      return nil unless enabled?

      listing.merge(url: url, headers: headers, public_only: !MCPHostGuard.allow_private?)
    end

    # This configuration as a header-free MCP server listing.
    #
    # @return [Hash]
    def listing
      {
        key: server_key,
        name: name,
        description: description.presence || "Your MCP server at #{display_url}",
        transport: "streamable_http",
        url: display_url,
        command: nil, package: nil, categories: [ "custom" ], docs_url: nil,
        sandbox: false, sandbox_type: nil, first_party: false,
        requires_credentials: [], tools: tool_names_list,
        custom: true, enabled: enabled?
      }
    end

    # The tool names the last successful test discovered.
    #
    # @return [Array<String>]
    def tool_names_list
      Array(tool_names).map(&:to_s)
    end

    # Calls tools/list on the server and records the outcome: the discovered
    # tool names on success, the error on failure. Uses the configuration as
    # it stands, saved or not, and saves it only when it is persisted.
    #
    # @param client [MCPClient, nil] the client to call, for tests
    # @return [Hash] +{ ok:, tools:, error:, latency_ms: }+
    def test_connection!(client: nil)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      client ||= MCPClient.new(url: url, label: name, headers: headers, public_only: !MCPHostGuard.allow_private?)
      names = client.list_tools.filter_map { |tool| (tool[:name] || tool["name"]).to_s.presence }.uniq.first(MAX_TOOL_NAMES)
      record_test(TEST_OK, tools: names)
      { ok: true, tools: names, error: nil, latency_ms: elapsed_ms(started) }
    rescue MCPClient::Error, URI::Error => e
      record_test(TEST_FAILED, error: e.message)
      { ok: false, tools: tool_names_list, error: e.message, latency_ms: elapsed_ms(started) }
    end

    # The configuration for the browser: never a header value.
    #
    # @return [Hash]
    def as_api_json
      {
        id: id,
        key: server_key,
        name: name,
        description: description,
        url: url,
        enabled: enabled?,
        headers: header_hints,
        tools: tool_names_list,
        last_tested_at: last_tested_at&.iso8601,
        last_test_status: last_test_status,
        last_test_error: last_test_error,
        updated_at: updated_at&.iso8601
      }
    end

    private

    # The URL without its query string, which can carry a token.
    def display_url
      uri = URI.parse(url.to_s)
      uri.query = nil
      uri.fragment = nil
      uri.to_s
    rescue URI::InvalidURIError
      url.to_s
    end

    def record_test(status, tools: nil, error: nil)
      self.last_tested_at = Time.current
      self.last_test_status = status
      self.last_test_error = error.to_s.first(1000).presence
      self.tool_names = tools unless tools.nil?
      save!(validate: false) if persisted?
    end

    def elapsed_ms(started)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    end

    # "••••a1b2" for a long value, "••••" for a short one, whose last
    # characters would give away too much of it.
    def mask(value)
      value.to_s.length >= 16 ? "••••#{value.to_s.last(4)}" : "••••"
    end

    def url_is_reachable_address
      return if url.blank?

      reason = MCPHostGuard.url_refusal(url)
      errors.add(:url, reason) if reason
    end

    def headers_are_valid
      current = headers
      errors.add(:headers, "can hold at most #{MAX_HEADERS} entries") if current.size > MAX_HEADERS

      seen = Set.new
      current.each do |name, value|
        if !HEADER_NAME.match?(name)
          errors.add(:headers, "#{name.inspect} is not a valid header name")
        elsif RESERVED_HEADERS.include?(name.downcase)
          errors.add(:headers, "#{name} is set by the MCP client and cannot be replaced")
        elsif !seen.add?(name.downcase)
          errors.add(:headers, "#{name} is listed twice")
        end

        if value.strip.empty?
          errors.add(:headers, "#{name} needs a value")
        elsif value.length > MAX_HEADER_VALUE_LENGTH
          errors.add(:headers, "#{name} is longer than #{MAX_HEADER_VALUE_LENGTH} characters")
        elsif value.match?(/[\r\n\0]/)
          errors.add(:headers, "#{name} must not contain line breaks")
        end
      end
    end
  end
end
