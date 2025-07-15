require "test_helper"

module ActiveAgent
  module ActionPrompt
    class PromptTest < ActiveSupport::TestCase
      test "initializes with default attributes" do
        prompt = Prompt.new

        assert_equal({}, prompt.options)
        assert_equal ApplicationAgent, prompt.agent_class
        assert_equal [], prompt.actions
        assert_equal "", prompt.action_choice
        assert_equal "", prompt.instructions
        assert_equal "", prompt.body
        assert_equal "text/plain", prompt.content_type
        assert_nil prompt.message
        assert_equal [], prompt.messages
        assert_equal({}, prompt.params)
        assert_equal "1.0", prompt.mime_version
        assert_equal "UTF-8", prompt.charset
        assert_equal [], prompt.context
        assert_nil prompt.context_id
        assert_equal({}, prompt.instance_variable_get(:@headers))
        assert_equal [], prompt.parts
      end

      test "initializes with custom attributes" do
        attributes = {
          options: { key: "value" },
          agent_class: ApplicationAgent,
          actions: [ "action1" ],
          action_choice: "action1",
          instructions: "Test instructions",
          body: "Test body",
          content_type: "application/json",
          message: "Test message",
          messages: [ Message.new(content: "Existing message") ],
          params: { param1: "value1" },
          mime_version: "2.0",
          charset: "ISO-8859-1",
          context: [ "context1" ],
          context_id: "123",
          headers: { "Header-Key" => "Header-Value" },
          parts: [ "part1" ]
        }

        prompt = Prompt.new(attributes)

        assert_equal attributes[:options], prompt.options
        assert_equal attributes[:agent_class], prompt.agent_class
        assert_equal attributes[:actions], prompt.actions
        assert_equal attributes[:action_choice], prompt.action_choice
        assert_equal attributes[:instructions], prompt.instructions
        assert_equal attributes[:body], prompt.body
        assert_equal attributes[:content_type], prompt.content_type
        assert_equal attributes[:message], prompt.message.content
        assert_equal ([ Message.new(content: "Test instructions", role: :system) ] + attributes[:messages]).map(&:to_h), prompt.messages.map(&:to_h)
        assert_equal attributes[:params], prompt.params
        assert_equal attributes[:mime_version], prompt.mime_version
        assert_equal attributes[:charset], prompt.charset
        assert_equal attributes[:context], prompt.context
        assert_equal attributes[:context_id], prompt.context_id
        assert_equal attributes[:headers], prompt.instance_variable_get(:@headers)
        assert_equal attributes[:parts], prompt.parts
      end

      test "to_s returns message content as string" do
        prompt = Prompt.new(message: "Test message")
        assert_equal "Test message", prompt.to_s
      end

      test "from_messages initializes messages from an array of Message objects" do
        prompt = Prompt.new(
          messages: [
            { content: "Hello, how can I assist you today?", role: :assistant },
            { content: "I need help with my account.", role: :user }
          ]
        )

        assert_equal 2, prompt.messages.size
        assert_equal "Hello, how can I assist you today?", prompt.messages.first.content
        assert_equal :assistant, prompt.messages.first.role
        assert_equal "I need help with my account.", prompt.messages.last.content
        assert_equal :user, prompt.messages.last.role
      end

      test "from_messages initializes messages from an array of Message objects with instructions" do
        prompt = Prompt.new(
          messages: [
            { content: "Hello, how can I assist you today?", role: :assistant },
            { content: "I need help with my account.", role: :user }
          ],
          instructions: "System instructions"
        )

        assert_equal 3, prompt.messages.size
        assert_equal "System instructions", prompt.messages.first.content
        assert_equal :system, prompt.messages.first.role
        assert_equal "Hello, how can I assist you today?", prompt.messages.second.content
        assert_equal :assistant, prompt.messages.second.role
        assert_equal "I need help with my account.", prompt.messages.last.content
        assert_equal :user, prompt.messages.last.role
      end

      test "to_h returns hash representation of prompt" do
        instructions = Message.new(content: "Test instructions", role: :system)
        message = Message.new(content: "Test message")
        prompt = Prompt.new(
          actions: [ "action1" ],
          action_choice: "action1",
          instructions: instructions.content,
          message: message,
          messages: [],
          headers: { "Header-Key" => "Header-Value" },
          context: [ "context1" ]
        )
        expected_hash = {
          actions: [ "action1" ],
          action: "action1",
          instructions: instructions.content,
          message: message.to_h,
          messages: [ instructions.to_h, message.to_h ],
          headers: { "Header-Key" => "Header-Value" },
          context: [ "context1" ]
        }

        assert_equal expected_hash, prompt.to_h
      end

      test "add_part adds a message to parts and updates message" do
        message = Message.new(content: "Part message", content_type: "text/plain")
        prompt = Prompt.new(content_type: "text/plain")

        prompt.add_part(message)

        assert_equal message, prompt.message
        assert_includes prompt.parts, message
      end

      test "multipart? returns true if parts are present" do
        prompt = Prompt.new
        assert_not prompt.multipart?

        prompt.add_part(Message.new(content: "Part message"))
        assert prompt.multipart?
      end

      test "headers method merges new headers" do
        prompt = Prompt.new(headers: { "Existing-Key" => "Existing-Value" })
        prompt.headers("New-Key" => "New-Value")

        expected_headers = { "Existing-Key" => "Existing-Value", "New-Key" => "New-Value" }
        assert_equal expected_headers, prompt.instance_variable_get(:@headers)
      end

      test "set_messages adds system message if instructions are present" do
        prompt = Prompt.new(instructions: "System instructions")
        assert_equal 1, prompt.messages.size
        assert_equal "System instructions", prompt.messages.first.content
        assert_equal :system, prompt.messages.first.role
      end

      test "set_message creates a user message from string" do
        prompt = Prompt.new(message: "User message")
        assert_equal "User message", prompt.message.content
        assert_equal :user, prompt.message.role
      end

      test "set_message creates a user message from body if message content is blank" do
        prompt = Prompt.new(body: "Body content", message: Message.new(content: ""))
        assert_equal "Body content", prompt.message.content
        assert_equal :user, prompt.message.role
      end

      test "initializes with actions, message, and messages example" do
        # region support_agent_prompt_initialization
        prompt = ActiveAgent::ActionPrompt::Prompt.new(
          actions: SupportAgent.new.action_schemas,
          message: "I need help with my account.",
          messages: [
            { content: "Hello, how can I assist you today?", role: :assistant }
          ]
        )
        # endregion support_agent_prompt_initialization

        assert_equal "get_cat_image", prompt.actions.first["function"]["name"]
        assert_equal "I need help with my account.", prompt.message.content
        assert_equal :user, prompt.message.role
        assert_equal 2, prompt.messages.size
        assert_equal "Hello, how can I assist you today?", prompt.messages.first.content
        assert_equal :assistant, prompt.messages.first.role
        assert_equal "I need help with my account.", prompt.messages.last.content
        assert_equal :user, prompt.messages.last.role
      end

      test "initializes with erb instructions" do
        # region support_agent_prompt_initialization_with_erb
        prompt = ActiveAgent::ActionPrompt::Prompt.new(
          instructions: "support_agent_instructions",
          agent_class: SupportAgent,
          actions: SupportAgent.new.action_schemas,
          message: "I need help with my account.",
          messages: [
            { content: "Hello, how can I assist you today?", role: :assistant }
          ]
        )
        # endregion support_agent_prompt_initialization_with_erb

        assert_equal "You are a support agent. That is all.", prompt.instructions
      end

      test "initializes with erb default path instructions" do
        # region support_agent_prompt_initialization_with_erb
        prompt = ActiveAgent::ActionPrompt::Prompt.new(
          agent_class: SupportAgent,
          actions: SupportAgent.new.action_schemas,
          message: "I need help with my account.",
          messages: [
            { content: "Hello, how can I assist you today?", role: :assistant }
          ]
        )
        # endregion support_agent_prompt_initialization_with_erb

        assert_equal "Default instructions for support agents.", prompt.instructions
      end
    end
  end
end
