require "test_helper"
require "solid_agent"

class SolidAgent::ContextualTest < ActiveSupport::TestCase
  # Define test models
  class Chat < ActiveRecord::Base
    self.table_name = "chats"
    has_many :messages, class_name: "ChatMessage"
    belongs_to :user
    
    include SolidAgent::Contextual
    
    contextual :chat,
               context: self,
               messages: :messages,
               user: :user
  end
  
  class ChatMessage < ActiveRecord::Base
    self.table_name = "chat_messages"
    belongs_to :chat
    
    def role
      sender_type == "User" ? "user" : "assistant"
    end
  end
  
  class Conversation < ActiveRecord::Base
    self.table_name = "conversations"
    
    include SolidAgent::Contextual
    
    contextual :conversation,
               messages: -> { messages.ordered },
               metadata: -> { { tags: tags, priority: priority } }
    
    def messages
      # Simulate message collection
      OpenStruct.new(
        ordered: [
          OpenStruct.new(content: "Hello", role: "user"),
          OpenStruct.new(content: "Hi there", role: "assistant")
        ]
      )
    end
    
    def tags
      ["support", "billing"]
    end
    
    def priority
      "high"
    end
  end
  
  setup do
    # Create test schema
    ActiveRecord::Base.connection.create_table :chats, force: true do |t|
      t.references :user
      t.string :status
      t.timestamps
    end
    
    ActiveRecord::Base.connection.create_table :chat_messages, force: true do |t|
      t.references :chat
      t.string :sender_type
      t.text :content
      t.timestamps
    end
    
    ActiveRecord::Base.connection.create_table :conversations, force: true do |t|
      t.string :status
      t.timestamps
    end
    
    @user = User.create!(name: "Test User")
    @chat = Chat.create!(user: @user)
    @message1 = ChatMessage.create!(chat: @chat, sender_type: "User", content: "Hello")
    @message2 = ChatMessage.create!(chat: @chat, sender_type: "Assistant", content: "Hi there")
  end
  
  teardown do
    ActiveRecord::Base.connection.drop_table :chat_messages if ActiveRecord::Base.connection.table_exists?(:chat_messages)
    ActiveRecord::Base.connection.drop_table :chats if ActiveRecord::Base.connection.table_exists?(:chats)
    ActiveRecord::Base.connection.drop_table :conversations if ActiveRecord::Base.connection.table_exists?(:conversations)
  end
  
  test "configures contextual type" do
    assert_equal "chat", Chat.contextual_type
    assert_equal "conversation", Conversation.contextual_type
  end
  
  test "creates prompt generation cycles" do
    cycle = @chat.start_prompt_cycle(TestAgent) do |c|
      c.prompt_metadata[:test] = true
    end
    
    assert_instance_of SolidAgent::Models::PromptGenerationCycle, cycle
    assert_equal @chat, cycle.contextual
    assert_equal "prompting", cycle.status
    assert cycle.prompt_metadata[:test]
  end
  
  test "converts to prompt context" do
    context = @chat.to_prompt_context
    
    assert_instance_of SolidAgent::Models::PromptContext, context
    assert_equal @chat, context.contextual
    assert_equal "chat", context.context_type
  end
  
  test "converts messages to SolidAgent format" do
    messages = @chat.to_solid_messages
    
    assert_equal 2, messages.count
    assert_equal "user", messages.first.role
    assert_equal "Hello", messages.first.content
    assert_equal "assistant", messages.second.role
    assert_equal "Hi there", messages.second.content
  end
  
  test "handles lambda message sources" do
    conversation = Conversation.create!
    messages = conversation.to_solid_messages
    
    assert_equal 2, messages.count
    assert_equal "Hello", messages.first.content
    assert_equal "Hi there", messages.second.content
  end
  
  test "extracts metadata correctly" do
    conversation = Conversation.create!
    context = conversation.to_prompt_context
    
    assert_equal ["support", "billing"], context.metadata[:tags]
    assert_equal "high", context.metadata[:priority]
  end
  
  test "determines message roles from various sources" do
    # Test with explicit role method
    msg_with_role = OpenStruct.new(role: "system", content: "Instructions")
    
    # Test with sender_type
    msg_with_sender = OpenStruct.new(sender_type: "User", content: "Question")
    
    # Test with from_ai? method
    msg_with_ai_flag = OpenStruct.new(from_ai?: true, content: "Response")
    
    config = SolidAgent::Contextual::ContextualConfiguration.new(Chat)
    
    assert_equal "system", config.send(:default_role_determiner).call(msg_with_role)
    assert_equal "user", config.send(:default_role_determiner).call(msg_with_sender)
    assert_equal "assistant", config.send(:default_role_determiner).call(msg_with_ai_flag)
  end
  
  test "detects content types" do
    config = SolidAgent::Contextual::ContextualConfiguration.new(Chat)
    detector = config.send(:default_content_type_detector)
    extractor = config.send(:default_content_extractor)
    
    text_msg = OpenStruct.new(content: "Plain text")
    array_msg = OpenStruct.new(content: [{ type: "text", text: "Hello" }])
    hash_msg = OpenStruct.new(content: { data: "structured" })
    
    assert_equal "text", detector.call(text_msg)
    assert_equal "multimodal", detector.call(array_msg)
    assert_equal "structured", detector.call(hash_msg)
  end
  
  test "completes generation cycle" do
    cycle = @chat.start_prompt_cycle(TestAgent)
    
    generation_data = {
      prompt_tokens: 100,
      completion_tokens: 50,
      total_tokens: 150,
      cost: 0.003
    }
    
    @chat.complete_generation_cycle(cycle, generation_data)
    
    cycle.reload
    assert_equal "completed", cycle.status
    assert_not_nil cycle.completed_at
  end
  
  test "registers contextual types" do
    # This would normally register with a central registry
    assert Chat.respond_to?(:contextual_type)
    assert Conversation.respond_to?(:contextual_type)
  end
end