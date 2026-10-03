# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "uri"

module ActiveAgent
  module Integrations
    # Optional HTTP integration. Requiring this file performs no network access.
    module Memcode
      class Error < StandardError; end

      class Client
        def initialize(api_key:, api_url: "https://memory.memcode.in", timeout: 5, transport: nil)
          @api_url = URI(api_url)
          unless @api_url.scheme == "https" && @api_url.host && !@api_url.userinfo &&
              !@api_url.query && !@api_url.fragment && [ "", "/" ].include?(@api_url.path)
            raise ArgumentError, "MemCode requires an HTTPS origin"
          end
          raise ArgumentError, "MemCode API key is required" if api_key.to_s.strip.empty?
          raise ArgumentError, "timeout must be positive" unless timeout.is_a?(Numeric) && timeout > 0

          @api_key, @timeout, @transport = api_key, timeout, transport
        end

        def ingest(space_id:, actor_id:, content:, metadata:, idempotency_key:)
          request("/v2/memory/ingest", {
            space_id: space_id, actor_id: actor_id, content: content, metadata: metadata
          }, idempotency_key: idempotency_key)
        end

        def search(space_id:, actor_id:, query:, limit:)
          request("/v2/memory/search", {
            context_space_id: space_id, actor_id: actor_id, query: query,
            scope: "context_only", mode: "memories", include_original_chunks: false, top_k: limit
          })
        end

        def ingest_status(job_id)
          id = job_id.to_s
          raise ArgumentError, "job ID is required" if id.strip.empty?
          request("/v2/memory/ingest/#{URI.encode_www_form_component(id)}", nil)
        end

        private

        def request(path, payload, idempotency_key: nil)
          uri = @api_url + path
          req = payload ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
          req["Authorization"] = "Bearer #{@api_key}"
          req["Content-Type"] = "application/json"
          req["Idempotency-Key"] = idempotency_key if idempotency_key
          req.body = JSON.generate(payload) if payload
          response = if @transport
            @transport.call(uri, req)
          else
            Net::HTTP.start(uri.host, uri.port, use_ssl: true,
              open_timeout: @timeout, read_timeout: @timeout, write_timeout: @timeout) do |http|
              http.request(req)
            end
          end
          raise Error, "MemCode request failed (HTTP #{response.code.to_i})" unless response.code.to_i.between?(200, 299)
          raise Error, "MemCode response is too large" if response.body.to_s.bytesize > 1_048_576
          envelope = JSON.parse(response.body)
          unless envelope.is_a?(Hash) && envelope["status"] == "ok" && envelope["data"].is_a?(Hash)
            raise Error, "MemCode returned an invalid response"
          end
          envelope.fetch("data")
        rescue JSON::ParserError
          raise Error, "MemCode returned invalid JSON"
        rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError
          raise Error, "MemCode is unavailable"
        end
      end

      # Construct this in trusted application code after authorizing the user/space.
      # The model receives query/content only, never identity or credentials.
      class Memory
        def initialize(client:, space_id:, user_id:, actor_id:)
          @client = client
          @space_id = required(space_id)
          @user_id = required(user_id)
          @actor_id = required(actor_id)
        end

        # Call only after the application has approved this exact content.
        # This is deliberately not exposed as an automatically callable model tool.
        def remember(content:)
          content = required(content)
          metadata = { "user_id" => @user_id, "source" => "user", "scope" => "user" }
          key = Digest::SHA256.hexdigest(JSON.generate([ @space_id, @user_id, content ]))
          @client.ingest(space_id: @space_id, actor_id: @actor_id, content: content,
            metadata: metadata, idempotency_key: "activeagent:#{key}")
        end

        def recall(query:, limit: 5)
          raise ArgumentError, "limit must be between 1 and 20" unless limit.is_a?(Integer) && limit.between?(1, 20)
          data = @client.search(space_id: @space_id, actor_id: @actor_id,
            query: required(query), limit: limit)
          results = data.fetch("results", [])
          raise Error, "MemCode returned invalid results" unless results.is_a?(Array)
          results.each_with_object([]) do |item, memories|
            next unless item.is_a?(Hash) && item["space"].is_a?(Hash) &&
              item["metadata"].is_a?(Hash) && item["space"]["id"] == @space_id &&
              item["metadata"]["user_id"] == @user_id && item["content"].is_a?(String)
            memories << { "content" => item["content"], "score" => item["score"] }
          end
        end

        private

        def required(value)
          raise ArgumentError, "memory scope and content must be non-empty strings" unless value.is_a?(String) && !value.strip.empty?
          value.dup.freeze
        end
      end
    end
  end
end
