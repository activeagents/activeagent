# frozen_string_literal: true

require "net/http"

module ActionAgent
  # Checks that an Ollama (or any OpenAI-compatible) endpoint is reachable and
  # lists the models it serves. Used by Settings -> Provider API Keys ("Test
  # connection") and by the agent builder's live model catalog.
  #
  # The host is the OpenAI-compatible base URL (".../v1"); the probe calls
  # GET {host}/models. An optional API key is sent as a Bearer token for
  # remote servers behind an authenticating proxy or Ollama Cloud.
  #
  # The result says whether the host is Ollama Cloud (`cloud`) and, for
  # each listed model a price list names, its rate (`rates`): the cloud's
  # models are metered per token, and a local server's copy of a cloud
  # model is priced at the same list rate (ModelPricing). A model priced
  # only by a guess has no entry.
  class OllamaHostProbe
    TIMEOUT_SECONDS = 4
    CLOUD_HOST = "ollama.com"

    Result = Struct.new(:ok, :host, :models, :latency_ms, :error, :cloud, :rates, keyword_init: true) do
      def to_h
        { ok: ok, host: host, models: models, latency_ms: latency_ms, error: error, cloud: cloud, rates: rates }
      end
    end

    def self.call(host:, api_key: nil)
      new(host: host, api_key: api_key).call
    end

    # Whether +host+ addresses Ollama Cloud (the framework's
    # ActiveAgent::Providers::Ollama::Cloud.cloud_host?, kept in step).
    def self.cloud_host?(host)
      name = URI.parse(host.to_s.strip).host.to_s.downcase
      name == CLOUD_HOST || name.end_with?(".#{CLOUD_HOST}")
    rescue URI::InvalidURIError
      false
    end

    def initialize(host:, api_key: nil)
      @host = ProviderKey.normalize_host(host)
      @api_key = api_key.presence
    end

    def cloud?
      self.class.cloud_host?(@host)
    end

    def call
      return failure("No host configured") if @host.blank?

      uri = URI.join("#{@host.chomp('/')}/", "models")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: TIMEOUT_SECONDS,
        read_timeout: TIMEOUT_SECONDS
      ) { |http| http.get(uri.request_uri, headers) }
      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

      status = response.code.to_i
      unless status == 200
        hint = " — check the API key" if [ 401, 403 ].include?(status)
        return failure("#{uri} responded #{status}#{hint}", latency_ms)
      end

      data = JSON.parse(response.body)
      models = Array(data["data"]).filter_map { |model| model["id"] }.sort
      Result.new(ok: true, host: @host, models: models, latency_ms: latency_ms, error: nil, cloud: cloud?, rates: rates_for(models))
    rescue JSON::ParserError
      failure("#{@host} did not return JSON — is this the OpenAI-compatible /v1 endpoint?")
    rescue URI::InvalidURIError, ArgumentError
      failure("#{@host} is not a valid URL")
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError => e
      failure("Could not connect to #{@host} (#{e.class.name.demodulize}) — is the server running and reachable from this machine?")
    rescue Net::OpenTimeout, Net::ReadTimeout
      failure("Timed out after #{TIMEOUT_SECONDS}s connecting to #{@host}")
    rescue StandardError => e
      failure("#{e.class}: #{e.message}")
    end

    private

    def headers
      @api_key ? { "Authorization" => "Bearer #{@api_key}" } : {}
    end

    # `{ "gpt-oss:120b" => { input: 0.15, output: 0.6, source: "catalog" } }`
    # for every listed model a price list names, in $ per million tokens.
    def rates_for(models)
      provider = cloud? ? ModelPricing::OLLAMA_CLOUD_PROVIDER : "ollama"
      models.each_with_object({}) do |id, rates|
        detail = ModelPricing.rate_detail(id, provider: provider)
        next if ModelPricing::FALLBACK_SOURCES.include?(detail[:source])

        rates[id] = detail.slice(:input, :output, :source)
      end
    end

    def failure(message, latency_ms = nil)
      Result.new(ok: false, host: @host, models: [], latency_ms: latency_ms, error: message, cloud: cloud?, rates: {})
    end
  end
end
