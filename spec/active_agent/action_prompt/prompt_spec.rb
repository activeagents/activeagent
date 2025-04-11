require "spec_helper"

RSpec.describe ActiveAgent::ActionPrompt::Prompt do
  describe "#initialize" do
    context "with default attributes" do
      subject(:prompt) { described_class.new }

      it "sets default values" do
        expect(prompt.options).to eq({})
        expect(prompt.actions).to eq([])
        expect(prompt.body).to eq("")
        expect(prompt.content_type).to eq("text/plain")
        expect(prompt.mime_version).to eq("1.0")
        expect(prompt.charset).to eq("UTF-8")
        expect(prompt.context).to eq([])
      end

      it "initializes with an empty message" do
        expect(prompt.message).to be_a(ActiveAgent::ActionPrompt::Message)
        expect(prompt.message.content).to eq("")
      end
    end

    context "with custom attributes" do
      let(:attributes) do
        {
          options: { foo: "bar" },
          actions: [ "action1" ],
          body: "test body",
          content_type: "text/markdown",
          instructions: "test instructions",
          charset: "ASCII"
        }
      end

      subject(:prompt) { described_class.new(attributes) }

      it "sets custom values" do
        expect(prompt.options).to eq({ foo: "bar" })
        expect(prompt.actions).to eq([ "action1" ])
        expect(prompt.body).to eq("test body")
        expect(prompt.content_type).to eq("text/markdown")
        expect(prompt.charset).to eq("ASCII")
      end
    end
  end

  describe "#to_h" do
    let(:message) { ActiveAgent::ActionPrompt::Message.new(content: "test content", role: :user) }
    let(:attributes) do
      {
        actions: [ "action1" ],
        action_choice: "choice1",
        instructions: "test instructions",
        message: message,
        context: [ "context1" ]
      }
    end

    subject(:prompt) { described_class.new(attributes) }

    it "returns correct hash representation" do
      expect(prompt.to_h).to eq({
        actions: [ "action1" ],
        action: "choice1",
        instructions: attributes[:instructions],
        message: message.to_h,
        messages: [ ActiveAgent::ActionPrompt::Message.new(role: :system, content: attributes[:instructions]).to_h, message.to_h ],
        headers: {},
        context: [ "context1" ]
      })
    end
  end

  describe "#add_part" do
    subject(:prompt) { described_class.new }

    let(:prompt_part) do
      {
        body: "part content",
        content_type: "text/plain",
        charset: "UTF-8"
      }
    end

    it "adds a new part to the prompt" do
      prompt.add_part(prompt_part)
      expect(prompt.multipart?).to be true
      expect(prompt.parts.length).to eq(1)
    end
  end

  describe "#set_message" do
    context "when initialized with string body" do
      subject(:prompt) { described_class.new(body: "test body") }

      it "creates a user message with body content" do
        expect(prompt.message.content).to eq("test body")
        expect(prompt.message.role).to eq(:user)
      end
    end

    context "when initialized with string message" do
      subject(:prompt) do
        described_class.new(message: ActiveAgent::ActionPrompt::Message.new(content: "test message", role: :user))
      end

      it "creates a user message with message content" do
        expect(prompt.message.content).to eq("test message")
        expect(prompt.message.role).to eq(:user)
      end
    end
  end
end
