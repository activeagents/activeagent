# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"
require_relative "cloud"

module ActiveAgent
  module Providers
    module Ollama
      # The models an Ollama host serves, from the host's own API: GET
      # /api/tags lists them and POST /api/show describes one. Works against
      # a local server and against Ollama Cloud alike. The host is the
      # provider's base URL (".../v1"); the native API lives beside it.
      #
      #   catalog = ActiveAgent::Providers::Ollama::Catalog.new(host: "https://ollama.com", api_key: ENV["OLLAMA_API_KEY"])
      #   catalog.models.map(&:name)         # => ["gpt-oss:120b", "kimi-k3", ...]
      #   catalog.model_info("gpt-oss:120b") # => #<struct Model name="gpt-oss:120b", cloud=true, capabilities=["completion", "tools", "thinking"], ...>
      #
      # A local server lists the cloud models it relays (`gpt-oss:120b-cloud`)
      # beside the ones it runs itself, and each Model says which it is. A
      # server with no native API — an OpenAI-compatible proxy in front of
      # one — is listed through GET /v1/models instead, which names models
      # and nothing else.
      #
      # Prices are not here: the host's API does not publish them. The
      # dashboard's ActionAgent::ModelPricing prices a cloud model by its
      # canonical name.
      class Catalog
        class Error < StandardError; end
        # The host could not be reached, or did not answer in time.
        class ConnectionError < Error; end
        # The host refused the API key (401 or 403).
        class AuthenticationError < Error; end
        # The host does not serve the model asked about.
        class NotFoundError < Error; end

        DEFAULT_TIMEOUT = 10

        # One model, as the host lists (#models) or describes (#model_info)
        # it. A listing carries details and size; a description adds the
        # capabilities and the context length.
        Model = Struct.new(:name, :cloud, :details, :capabilities, :context_length, :size, :modified_at, :raw,
                           keyword_init: true) do
          # The name the cloud's catalog and price list use (Cloud.canonical_model).
          def canonical_name
            Cloud.canonical_model(name)
          end

          # Whether Ollama Cloud serves the model: listed by the cloud, or
          # relayed to it by a local server.
          def cloud?
            cloud == true
          end

          def family
            details["family"]
          end

          def parameter_size
            details["parameter_size"]
          end

          def quantization_level
            details["quantization_level"]
          end

          def to_h
            {
              name: name, canonical_name: canonical_name, cloud: cloud?, details: details,
              capabilities: capabilities, context_length: context_length, size: size, modified_at: modified_at
            }
          end
        end

        attr_reader :host, :timeout

        # @param host [String] the server address, bare or with its /v1 path
        # @param api_key [String, nil] sent as a Bearer token; the local
        #   placeholder is not sent
        # @param timeout [Numeric] seconds to connect and to read
        def initialize(host:, api_key: nil, timeout: DEFAULT_TIMEOUT)
          @host = Cloud.normalize_host(host) || Cloud::LOCAL_BASE_URL
          key = api_key.to_s.strip
          @api_key = key unless key.empty? || key == Cloud::PLACEHOLDER_API_KEY
          @timeout = timeout
        end

        # @return [Boolean] whether the host is Ollama Cloud
        def cloud?
          Cloud.cloud_host?(host)
        end

        # The models the host serves.
        #
        # @return [Array<Model>]
        # @raise [Error]
        def models
          response = request(Net::HTTP::Get, "/api/tags", allow_not_found: true)
          return openai_models if response.code.to_i == 404

          Array(parse(response, "/api/tags")["models"]).filter_map { |entry| from_listing(entry) }
        end

        # @return [Array<String>] the names of the models the host serves
        def model_names
          models.map(&:name)
        end

        # One model, described: its details, capabilities and context length.
        #
        # @param name [String]
        # @return [Model]
        # @raise [NotFoundError] when the host does not serve +name+
        # @raise [Error]
        def model_info(name)
          response = request(Net::HTTP::Post, "/api/show", { model: name.to_s }, allow_not_found: true)
          raise NotFoundError, "#{host} does not serve #{name}" if response.code.to_i == 404

          from_show(name.to_s, parse(response, "/api/show"))
        end

        private

        def openai_models
          data = parse(request(Net::HTTP::Get, "/v1/models"), "/v1/models")
          Array(data["data"]).filter_map do |entry|
            id = entry.is_a?(Hash) ? entry["id"].to_s : ""
            next if id.empty?

            Model.new(name: id, cloud: cloud? || Cloud.cloud_model?(id), details: {}, capabilities: [], raw: entry)
          end
        end

        def from_listing(entry)
          return nil unless entry.is_a?(Hash)

          name = (entry["name"] || entry["model"]).to_s
          return nil if name.empty?

          Model.new(
            name: name,
            cloud: cloud_model?(name, entry),
            details: hash_at(entry, "details"),
            capabilities: Array(entry["capabilities"]).map(&:to_s),
            context_length: nil,
            size: entry["size"],
            modified_at: entry["modified_at"],
            raw: entry
          )
        end

        def from_show(name, data)
          info = hash_at(data, "model_info")
          architecture = info["general.architecture"]
          context_length = info["#{architecture}.context_length"] ||
            info.find { |key, _| key.to_s.end_with?(".context_length") }&.last

          Model.new(
            name: name,
            cloud: cloud_model?(name, data),
            details: hash_at(data, "details"),
            capabilities: Array(data["capabilities"]).map(&:to_s),
            context_length: context_length.is_a?(Numeric) ? context_length.to_i : nil,
            size: nil,
            modified_at: data["modified_at"],
            raw: data
          )
        end

        # Listed by the cloud itself, relayed to it by a local server (which
        # names the remote host), or spelled with the cloud marker.
        def cloud_model?(name, entry)
          cloud? || !entry["remote_host"].to_s.empty? || Cloud.cloud_model?(name)
        end

        def hash_at(data, key)
          value = data[key]
          value.is_a?(Hash) ? value : {}
        end

        def request(method_class, path, body = nil, allow_not_found: false)
          uri = URI.parse("#{Cloud.api_origin(host)}#{path}")
          request = method_class.new(uri.request_uri, headers)
          if body
            request["Content-Type"] = "application/json"
            request.body = JSON.generate(body)
          end

          response = Net::HTTP.start(
            uri.host, uri.port,
            use_ssl: uri.scheme == "https", open_timeout: timeout, read_timeout: timeout
          ) { |http| http.request(request) }

          status = response.code.to_i
          raise AuthenticationError, "#{uri} refused the API key (#{status})" if [ 401, 403 ].include?(status)
          return response if status == 200 || (status == 404 && allow_not_found)

          raise Error, "#{uri} responded #{status}"
        rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ECONNRESET, SocketError,
               Net::OpenTimeout, Net::ReadTimeout, IOError, OpenSSL::SSL::SSLError => e
          raise ConnectionError, "Could not reach #{host} (#{e.class.name.split('::').last}: #{e.message})"
        end

        def parse(response, path)
          data = JSON.parse(response.body.to_s)
          data.is_a?(Hash) ? data : {}
        rescue JSON::ParserError
          raise Error, "#{Cloud.api_origin(host)}#{path} did not return JSON"
        end

        def headers
          headers = { "Accept" => "application/json" }
          headers["Authorization"] = "Bearer #{@api_key}" if @api_key
          headers
        end
      end
    end
  end
end
