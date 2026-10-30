# frozen_string_literal: true

require "uri"

module ActiveAgent
  module Providers
    module Ollama
      # Ollama Cloud: the models Ollama serves from ollama.com, and the two
      # routes a request takes to them.
      #
      # Directly, the host is https://ollama.com, every request carries an
      # API key (https://ollama.com/settings/keys), and a model is named as
      # the cloud lists it: `gpt-oss:120b`. Through a local server signed in
      # to ollama.com (`ollama signin`), the host is the local one, no key is
      # needed, and the same model carries the local server's cloud marker:
      # `gpt-oss:120b-cloud`, or `glm-4.6:cloud`. These helpers tell the two
      # routes apart and reduce either spelling to the name the cloud's
      # catalog and price list use, so a trace or an evaluation prices the
      # model the same way whichever route served it. The dashboard's
      # ActionAgent::ModelPricing keeps a copy of the two naming rules, so a
      # change here needs the same change there.
      module Cloud
        HOST = "https://ollama.com"
        # The OpenAI-compatible endpoint the provider talks to.
        BASE_URL = "#{HOST}/v1"
        LOCAL_BASE_URL = "http://127.0.0.1:11434/v1"
        # The port the ollama command assumes when a host names none.
        DEFAULT_PORT = 11_434
        # The key a local server is sent when none is configured; it ignores
        # it, and the cloud refuses it.
        PLACEHOLDER_API_KEY = "ollama"
        # A local server's spellings of a cloud model.
        MODEL_SUFFIX = "-cloud"
        MODEL_TAG = ":cloud"

        module_function

        # Whether +url+ addresses Ollama Cloud.
        #
        # @param url [String, nil]
        # @return [Boolean]
        def cloud_host?(url)
          host = URI.parse(url.to_s.strip).host.to_s.downcase
          host == "ollama.com" || host.end_with?(".ollama.com")
        rescue URI::InvalidURIError
          false
        end

        # Whether +name+ carries a local server's cloud marker.
        #
        # @param name [String, nil]
        # @return [Boolean]
        def cloud_model?(name)
          name = name.to_s.strip
          name.end_with?(MODEL_SUFFIX) || name.end_with?(MODEL_TAG)
        end

        # The name the cloud lists a model under: "gpt-oss:120b-cloud" →
        # "gpt-oss:120b", "glm-4.6:cloud" → "glm-4.6"; any other name as given.
        #
        # @param name [String, nil]
        # @return [String]
        def canonical_model(name)
          name = name.to_s.strip
          return name.delete_suffix(MODEL_TAG) if name.end_with?(MODEL_TAG)
          return name.delete_suffix(MODEL_SUFFIX) if name.end_with?(MODEL_SUFFIX)

          name
        end

        # A server address as the base URL of its OpenAI-compatible API, read
        # the way the ollama command reads OLLAMA_HOST: a bare origin
        # (http://localhost:11434, https://ollama.com) gets the /v1 path, a
        # scheme-less "host[:port]" is http, an http address with no port is
        # on 11434, trailing slashes go, and an explicit path is kept for a
        # server behind a reverse proxy. nil for a blank value.
        #
        # @param value [String, nil]
        # @return [String, nil]
        def normalize_host(value)
          host = value.to_s.strip.chomp("/")
          return nil if host.empty?

          unless host.match?(%r{\A[a-z][a-z0-9+.-]*://}i)
            host = "#{cloud_host?("https://#{host}") ? 'https' : 'http'}://#{host}"
          end
          uri = URI.parse(host)
          return host unless uri.is_a?(URI::HTTP)

          uri.port = DEFAULT_PORT if uri.scheme == "http" && !host.match?(%r{\A[a-z][a-z0-9+.-]*://[^/]*:\d+}i)
          uri.path = "/v1" if uri.path.empty? || uri.path == "/"
          uri.to_s.chomp("/")
        rescue URI::InvalidURIError
          host
        end

        # Where the host's own API lives, beside its OpenAI-compatible one:
        # "https://ollama.com/v1" → "https://ollama.com", and a reverse-proxied
        # "https://ai.example.com/ollama/v1" → "https://ai.example.com/ollama".
        #
        # @param base_url [String]
        # @return [String]
        def api_origin(base_url)
          base_url.to_s.strip.chomp("/").delete_suffix("/v1")
        end
      end
    end
  end
end
