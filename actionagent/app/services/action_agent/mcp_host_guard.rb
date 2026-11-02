# frozen_string_literal: true

require "ipaddr"
require "resolv"
require "uri"

module ActionAgent
  # Decides whether the dashboard may call a user-supplied MCP server URL
  # (MCPServerConfig). Those servers are reached from the dashboard's own
  # network, so without a check any user could point one at an address only
  # the dashboard can reach: a cloud metadata endpoint, a database admin page
  # on the private network, the host's own loopback.
  #
  # The check runs twice:
  #
  # * When a configuration is saved, #url_refusal reads the URL alone, with
  #   no DNS lookup: the scheme is http or https, the URL carries no user
  #   name or password, and its host is not a literal non-public address or a
  #   localhost name.
  # * When MCPClient connects (+public_only: true+), #public_addresses!
  #   resolves the host and refuses it unless every address it resolves to
  #   is public. The client then connects to the address that was checked,
  #   so a name whose DNS answer changes between the check and the connection
  #   still reaches only a checked address.
  #
  # ActionAgent.allow_private_mcp_hosts switches both off, for local
  # development against a server on localhost.
  class MCPHostGuard
    SCHEMES = %w[http https].freeze

    # Addresses no public server is reached at, beyond what IPAddr already
    # names (loopback?, private?, link_local?): the unspecified "this host"
    # ranges, carrier-grade NAT, benchmarking, multicast and reserved space.
    NON_PUBLIC_RANGES = %w[
      0.0.0.0/8 100.64.0.0/10 192.0.0.0/24 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4
      ::/128 ff00::/8
    ].map { |range| IPAddr.new(range) }.freeze

    # Host names that resolve to the machine itself however DNS answers.
    LOCAL_NAMES = /\A(?:localhost|.+\.localhost|localhost\.localdomain)\z/i

    class << self
      # Resolves a host name to its addresses. Replaceable so tests need no
      # network.
      # @return [#call]
      attr_writer :resolver

      def resolver
        @resolver || Resolv.method(:getaddresses)
      end

      # Whether private addresses are allowed (ActionAgent.allow_private_mcp_hosts).
      def allow_private?
        ActionAgent.allow_private_mcp_hosts ? true : false
      end

      # Why +url+ cannot be saved as an MCP server URL, or nil when it can.
      # Reads the URL alone and resolves nothing.
      #
      # @param url [String]
      # @param allow_private [Boolean]
      # @return [String, nil]
      def url_refusal(url, allow_private: allow_private?)
        uri = URI.parse(url.to_s.strip)
        return "must be an http:// or https:// URL" unless SCHEMES.include?(uri.scheme.to_s.downcase)
        return "must name a host" if uri.hostname.blank?
        return "must not carry a user name or password; send credentials in a header instead" if uri.userinfo.present?
        return nil if allow_private

        host = uri.hostname
        return "must not point at localhost" if LOCAL_NAMES.match?(host)

        address = literal_address(host)
        return "must not point at a private, loopback or link-local address" if address && !public_address?(address)

        nil
      rescue URI::InvalidURIError
        "is not a valid URL"
      end

      # The addresses +host+ resolves to, every one of them public.
      #
      # @param host [String]
      # @return [Array<String>]
      # @raise [MCPClient::Error] when the host does not resolve, or resolves
      #   to any non-public address
      def public_addresses!(host)
        addresses = Array(resolver.call(host.to_s)).map(&:to_s).uniq
        raise MCPClient::Error, "#{host} does not resolve to an address" if addresses.empty?

        refused = addresses.reject { |address| public_address?(address) }
        if refused.any?
          raise MCPClient::Error,
                "#{host} resolves to a private, loopback or link-local address (#{refused.first}); " \
                "set ActionAgent.allow_private_mcp_hosts to reach it"
        end

        addresses
      rescue Resolv::ResolvError => e
        raise MCPClient::Error, "#{host} does not resolve: #{e.message}"
      end

      # Whether +address+ (an IP address string or IPAddr) is publicly
      # routable. An IPv4 address written as IPv6 (::ffff:127.0.0.1) is read
      # as the IPv4 address it carries. Anything that does not parse is not
      # public.
      #
      # @return [Boolean]
      def public_address?(address)
        ip = address.is_a?(IPAddr) ? address : IPAddr.new(address.to_s)
        ip = ip.native
        return false if ip.loopback? || ip.private? || ip.link_local?

        NON_PUBLIC_RANGES.none? { |range| range.family == ip.family && range.include?(ip) }
      rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
        false
      end

      private

      # +host+ as an IPAddr when it is an IP literal, nil when it is a name.
      def literal_address(host)
        IPAddr.new(host)
      rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
        nil
      end
    end
  end
end
