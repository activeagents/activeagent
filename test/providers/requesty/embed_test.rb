# frozen_string_literal: true

require "test_helper"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping Requesty embed tests"
  return
end

require_relative "../../../lib/active_agent/providers/requesty_provider"

module Providers
  module Requesty
    class EmbedTest < ActiveSupport::TestCase
      include WebMock::API

      EMBEDDINGS_ENDPOINT = "https://router.requesty.ai/v1/embeddings"

      test "sends an embedding request to the Requesty embeddings endpoint" do
        stub_request(:post, EMBEDDINGS_ENDPOINT).to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: embedding_response.to_json
        )

        response = ActiveAgent::Providers::RequestyProvider.new(
          service: "Requesty",
          model: "openai/text-embedding-3-small",
          input: "hello",
          api_key: "rqsty-test"
        ).embed

        assert_equal [ 0.1, 0.2 ], response.data.first[:embedding]
        assert_requested(:post, EMBEDDINGS_ENDPOINT, headers: { "Authorization" => "Bearer rqsty-test" })
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
