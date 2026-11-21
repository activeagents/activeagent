# frozen_string_literal: true

require "test_helper"

begin
  require "openai"
rescue LoadError
  puts "OpenAI gem not available, skipping Azure embed tests"
  return
end

require_relative "../../../lib/active_agent/providers/azure_provider"

module Providers
  module Azure
    class EmbedTest < ActiveSupport::TestCase
      include WebMock::API

      EMBEDDINGS_ENDPOINT = "https://mycompany.openai.azure.com/openai/deployments/embed-deployment/embeddings"

      test "sends an embedding request to the Azure deployment embeddings endpoint" do
        stub_request(:post, EMBEDDINGS_ENDPOINT)
          .with(query: { "api-version" => "2024-10-21" })
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: embedding_response.to_json
          )

        response = ActiveAgent::Providers::AzureProvider.new(
          service: "AzureOpenAI",
          model: "text-embedding-3-small",
          input: "hello",
          api_key: "azure-test",
          azure_resource: "mycompany",
          deployment_id: "embed-deployment",
          api_version: "2024-10-21"
        ).embed

        assert_equal [ 0.1, 0.2 ], response.data.first[:embedding]
        assert_requested(
          :post, EMBEDDINGS_ENDPOINT,
          query: { "api-version" => "2024-10-21" },
          headers: { "api-key" => "azure-test" }
        )
      end

      private

      def embedding_response
        {
          object: "list",
          model: "text-embedding-3-small",
          data: [ { object: "embedding", index: 0, embedding: [ 0.1, 0.2 ] } ],
          usage: { prompt_tokens: 2, total_tokens: 2 }
        }
      end
    end
  end
end
