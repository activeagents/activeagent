# test/lib/active_agent/generation_provider/open_ai_provider_test.rb
require "active_agent/generation_provider/open_ai_provider"
describe ActiveAgent::GenerationProvider::OpenAIProvider do
  let(:config) do
    {
      "api_key" => "test_api_key",
      "model" => "gpt-3.5-turbo",
      "temperature" => 0.7
    }
  end

  let(:provider) { ActiveAgent::GenerationProvider::OpenAIProvider.new(config) }

  describe "#initialize" do
    it "sets the api_key and model_name" do
      assert_equal "test_api_key", provider.instance_variable_get(:@api_key)
      assert_equal "gpt-3.5-turbo", provider.instance_variable_get(:@model_name)
    end

    it "uses default model if not provided" do
      config_without_model = config.reject { |k, _| k == "model" }
      provider_without_model = ActiveAgent::GenerationProvider::OpenAIProvider.new(config_without_model)
      assert_equal "gpt-3.5-turbo", provider_without_model.instance_variable_get(:@model_name)
    end
  end

  describe "#generate" do
    let(:prompt) { OpenStruct.new(messages: [], message: OpenStruct.new(to_h: {role: "user", content: "Test prompt"})) }
    let(:client) { Minitest::Mock.new }
    let(:response) { {"choices" => [{"message" => {"content" => "Test response"}}]} }

    before do
      OpenAI::Client.stub :new, client do
        client.expect :chat, response, [{parameters: {messages: [{role: "user", content: "Test prompt"}], temperature: 0.7, model: "gpt-3.5-turbo"}}]
      end
    end

    it "generates a response" do
      OpenAI::Client.stub :new, client do
        result = provider.generate(prompt)
        assert_instance_of ActiveAgent::GenerationProvider::Response, result
        assert_equal "Test response", result.response["content"]
      end
    end

    it "handles errors" do
      OpenAI::Client.stub :new, ->(_) { raise StandardError.new("Test error") } do
        assert_raises(StandardError) { provider.generate(prompt) }
      end
    end
  end

  describe "#message" do
    it "extracts the message from the response" do
      message = {"choices" => [{"message" => "Test message"}]}
      assert_equal "Test message", provider.send(:message, message)
    end
  end

  describe "#response" do
    it "extracts the message from the response" do
      response = {"choices" => [{"message" => "Test message"}]}
      assert_equal "Test message", provider.send(:response, response)
    end
  end
end

describe "#generate with streaming" do
  let(:stream_proc) { proc { |message| puts message.content } }
  let(:config_with_stream) do
    config.merge("stream" => stream_proc)
  end
  let(:provider_with_stream) { ActiveAgent::GenerationProvider::OpenAIProvider.new(config_with_stream) }
  let(:prompt_with_stream) do
    OpenStruct.new(
      messages: [OpenStruct.new(response_number: 0, content: "")],
      config: {stream: stream_proc}
    )
  end
  let(:response_stream) do
    {
      "choices" => [
        {
          "delta" => {"content" => "Hello"},
          "index" => 0
        },
        {
          "delta" => {"content" => " World"},
          "index" => 0
        }
      ]
    }
  end

  it "handles streaming responses" do
    streamed_messages = []
    test_stream_proc = proc { |message| streamed_messages << message.content }

    client = Minitest::Mock.new
    client.expect :chat, nil, [Hash]

    OpenAI::Client.stub :new, client do
      provider_with_stream.instance_variable_set(:@client, client)
      provider_with_stream.instance_variable_set(:@prompt, prompt_with_stream)

      client.expect :chat, nil, [Hash]

      # Simulate streaming by calling the provider_stream proc manually
      stream = provider_with_stream.send(:provider_stream)
      response_stream["choices"].each do |chunk|
        stream.call(chunk, chunk.to_json.bytesize)
      end

      assert_equal ["Hello", " World"], streamed_messages
    end
  end
end
