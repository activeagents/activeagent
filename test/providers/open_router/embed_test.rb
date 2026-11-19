# frozen_string_literal: true

require "test_helper"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping OpenRouter embed tests"
  return
end

require_relative "../../../lib/active_agent/providers/open_router_provider"

module Providers
  module OpenRouter
    class EmbedTest < ActiveSupport::TestCase
      include WebMock::API

      EMBEDDINGS_ENDPOINT = "https://openrouter.ai/api/v1/embeddings"

      test "sends an embedding request to the OpenRouter embeddings endpoint" do
        stub_request(:post, EMBEDDINGS_ENDPOINT).to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: embedding_response.to_json
        )

        response = ActiveAgent::Providers::OpenRouterProvider.new(
          service: "OpenRouter",
          model: "openai/text-embedding-3-small",
          input: "hello",
          api_key: "or-test"
        ).embed

        assert_equal [ 0.1, 0.2 ], response.data.first[:embedding]
        assert_requested(:post, EMBEDDINGS_ENDPOINT, headers: { "Authorization" => "Bearer or-test" })
      end

      private

      def embedding_response
        {
          object: "list",
          model: "openai/text-embedding-3-small",
          data: [ { object: "embedding", index: 0, embedding: [ 0.1, 0.2 ] } ],
          usage: { prompt_tokens: 2, total_tokens: 2 }
        }
      end
    end
  end
end
