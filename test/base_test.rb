# test/active_agent/generation_provider/base_test.rb

require_relative "test_helper"
require "active_agent/generation_provider/base"
require "ostruct"
require "logger"

describe ActiveAgent::GenerationProvider::Base do
  let(:config) { {"temperature" => 0.5} }
  let(:base_provider) { ActiveAgent::GenerationProvider::Base.new(config) }

  before do
    @logger = Logger.new($stdout)
    ActiveAgent::GenerationProvider::Base.any_instance.stubs(:logger).returns(@logger)
  end

  describe "#initialize" do
    it "sets the config and initializes prompt to nil" do
      assert_equal config, base_provider.config
      assert_nil base_provider.prompt
    end
  end

  describe "#generate" do
    it "raises NotImplementedError" do
      assert_raises NotImplementedError do
        base_provider.generate("test prompt")
      end
    end
  end

  describe "#prompt_parameters" do
    it "returns a hash with messages and temperature" do
      base_provider.instance_variable_set(:@prompt, OpenStruct.new(instructions: nil, messages: [], message: nil))
      expected = {messages: [], temperature: 0.5}
      assert_equal expected, base_provider.send(:prompt_parameters)
    end

    it "uses default temperature when not provided in config" do
      base_provider = ActiveAgent::GenerationProvider::Base.new({})
      base_provider.instance_variable_set(:@prompt, OpenStruct.new(instructions: nil, messages: [], message: nil))
      expected = {messages: [], temperature: 0.7}
      assert_equal expected, base_provider.send(:prompt_parameters)
    end
  end

  describe "#extract_message_from_response" do
    it "raises NotImplementedError" do
      assert_raises NotImplementedError do
        base_provider.send(:extract_message_from_response, {})
      end
    end
  end

  describe "#handle_error" do
    it "logs the error and raises it" do
      error = StandardError.new("Test error")
      base_provider.expects(:logger).returns(@logger)
      @logger.expects(:error).with("ActiveAgent::GenerationProvider::Base Error: Test error")

      assert_raises StandardError do
        base_provider.send(:handle_error, error)
      end
    end
  end
end
