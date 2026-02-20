# frozen_string_literal: true

module ActiveAgent
  module Providers
    module Bedrock
      # Client for AWS Bedrock using bearer token (API key) authentication.
      #
      # Subclasses Anthropic::Client directly to reuse its built-in bearer
      # token support via the +auth_token+ parameter, while adding Bedrock-
      # specific request transformations (URL path rewriting, anthropic_version
      # injection) copied from Anthropic::BedrockClient.
      #
      # This avoids Anthropic::BedrockClient which requires SigV4 credentials
      # and would fail when only a bearer token is available.
      #
      # @see https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-use.html
      class BearerClient < ::Anthropic::Client
        BEDROCK_VERSION = "bedrock-2023-05-31"

        # @return [String]
        attr_reader :aws_region

        # @param aws_region [String] AWS region for the Bedrock endpoint
        # @param bearer_token [String] AWS Bedrock API key (bearer token)
        # @param base_url [String, nil] Override the default Bedrock endpoint
        # @param max_retries [Integer]
        # @param timeout [Float]
        # @param initial_retry_delay [Float]
        # @param max_retry_delay [Float]
        def initialize(
          aws_region:,
          bearer_token:,
          base_url: nil,
          max_retries: self.class::DEFAULT_MAX_RETRIES,
          timeout: self.class::DEFAULT_TIMEOUT_IN_SECONDS,
          initial_retry_delay: self.class::DEFAULT_INITIAL_RETRY_DELAY,
          max_retry_delay: self.class::DEFAULT_MAX_RETRY_DELAY
        )
          @aws_region = aws_region

          base_url ||= "https://bedrock-runtime.#{aws_region}.amazonaws.com"

          super(
            auth_token: bearer_token,
            api_key: nil,
            base_url: base_url,
            max_retries: max_retries,
            timeout: timeout,
            initial_retry_delay: initial_retry_delay,
            max_retry_delay: max_retry_delay
          )

          @messages = ::Anthropic::Resources::Messages.new(client: self)
          @completions = ::Anthropic::Resources::Completions.new(client: self)
          @beta = ::Anthropic::Resources::Beta.new(client: self)
        end

        private

        # Intercepts request building to apply Bedrock-specific transformations
        # before the parent class processes the request.
        def build_request(req, opts)
          fit_req_to_bedrock_specs!(req)
          req = super
          body = req.fetch(:body)
          req[:body] = StringIO.new(body.to_a.join) if body.is_a?(Enumerator)
          req
        end

        # Rewrites Anthropic API paths to Bedrock endpoint paths and injects
        # the Bedrock anthropic_version field.
        #
        # Adapted from Anthropic::Helpers::Bedrock::Client#fit_req_to_bedrock_specs!
        def fit_req_to_bedrock_specs!(request_components)
          if (body = request_components[:body]).is_a?(Hash)
            body[:anthropic_version] ||= BEDROCK_VERSION
            body.transform_keys!("anthropic-beta": :anthropic_beta)
          end

          case request_components[:path]
          in %r{^v1/messages/batches}
            raise NotImplementedError, "The Batch API is not supported in Bedrock yet"
          in %r{v1/messages/count_tokens}
            raise NotImplementedError, "Token counting is not supported in Bedrock yet"
          in %r{v1/models\?beta=true}
            raise NotImplementedError,
                  "Please instead use https://docs.anthropic.com/en/api/claude-on-amazon-bedrock#list-available-models " \
                  "to list available models on Bedrock."
          else
          end

          if %w[
            v1/complete
            v1/messages
            v1/messages?beta=true
          ].include?(request_components[:path]) && request_components[:method] == :post && body.is_a?(Hash)
            model = body.delete(:model)
            model = URI.encode_www_form_component(model.to_s)
            stream = body.delete(:stream) || false
            request_components[:path] =
              stream ? "model/#{model}/invoke-with-response-stream" : "model/#{model}/invoke"
          end

          request_components
        end
      end
    end
  end
end
