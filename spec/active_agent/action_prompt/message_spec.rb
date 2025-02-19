RSpec.describe ActiveAgent::ActionPrompt::Message do
  describe "#initialize" do
    context "with valid roles" do
      %w[system assistant user tool function].each do |valid_role|
        it "accepts '#{valid_role}' as a valid role" do
          expect {
            described_class.new(role: valid_role)
          }.not_to raise_error
        end
      end

      it "accepts role as symbol" do
        expect {
          described_class.new(role: :system)
        }.not_to raise_error
      end
    end

    context "with invalid role" do
      it "raises ArgumentError" do
        expect {
          described_class.new(role: "invalid_role")
        }.to raise_error(
          ArgumentError,
          "Invalid role: invalid_role. Valid roles are: system, assistant, user, tool, function"
        )
      end
    end
  end

  describe "#to_h" do
    it "returns a hash with basic attributes" do
      message = described_class.new(role: "user", content: "hello")
      expect(message.to_h).to eq({
        role: "user",
        content: "hello",
        action_requested: false
      })
    end

    it "includes name when present" do
      message = described_class.new(role: "user", content: "hello", name: "test_user")
      expect(message.to_h).to eq({
        role: "user",
        content: "hello",
        name: "test_user",
        action_requested: false
      })
    end

    it "includes requested_actions when present" do
      message = described_class.new(
        role: "user",
        content: "hello",
        requested_actions: ["action1", "action2"]
      )
      expect(message.to_h).to eq({
        role: "user",
        content: "hello",
        action_requested: true,
        requested_actions: ["action1", "action2"]
      })
    end
  end
end
