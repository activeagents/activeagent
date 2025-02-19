require "active_agent/generation_provider/base"

RSpec.describe ActiveAgent::GenerationProvider::Base do
  let(:messages) { [{role: "user", content: "test message"}] }
  let(:mock_prompt) { double("Prompt", messages: messages) }

  describe "#prompt_parameters" do
    context "with default configuration" do
      let(:config) { {} }
      let(:base) { described_class.new(config) }

      before do
        base.instance_variable_set(:@prompt, mock_prompt)
      end

      it "returns default temperature of 0.7" do
        expect(base.send(:prompt_parameters)[:temperature]).to eq(0.7)
      end

      it "includes messages from prompt" do
        expect(base.send(:prompt_parameters)[:messages]).to eq(messages)
      end

      it "returns complete parameters hash" do
        expected = {
          messages: messages,
          temperature: 0.7
        }
        expect(base.send(:prompt_parameters)).to eq(expected)
      end
    end

    context "with custom temperature" do
      let(:config) { {"temperature" => 0.9} }
      let(:base) { described_class.new(config) }

      before do
        base.instance_variable_set(:@prompt, mock_prompt)
      end

      it "uses temperature from config" do
        expect(base.send(:prompt_parameters)[:temperature]).to eq(0.9)
      end
    end
  end
end
