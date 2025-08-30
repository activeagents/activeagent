# frozen_string_literal: true

module SolidAgent
  # Contextual allows any ActiveRecord model to become a prompt context container
  # Similar to how ActionController handles Request-Response, we handle Prompt-Generation
  #
  # Example:
  #   class Chat < ApplicationRecord
  #     include SolidAgent::Contextual
  #     
  #     contextual :chat,
  #                context: self,
  #                messages: :messages,
  #                metadata: :properties
  #   end
  #
  #   class Conversation < ApplicationRecord
  #     include SolidAgent::Contextual
  #     
  #     contextual :conversation,
  #                context: self,
  #                messages: -> { messages.ordered },
  #                user: :participant,
  #                agent: -> { ai_assistant }
  #   end
  #
  module Contextual
    extend ActiveSupport::Concern

    included do
      class_attribute :contextual_configuration, default: {}
      class_attribute :contextual_type, default: nil
      
      # Every contextual model can have many prompt-generation cycles
      has_many :prompt_generation_cycles,
               class_name: "SolidAgent::Models::PromptGenerationCycle",
               as: :contextual,
               dependent: :destroy
    end

    class_methods do
      # DSL for defining contextual implementation
      def contextual(type, **options)
        self.contextual_type = type.to_s
        self.contextual_configuration = ContextualConfiguration.new(self, **options)
        
        # Set up associations based on configuration
        setup_contextual_associations
        
        # Include tracking methods
        include ContextualInstanceMethods
        
        # Register this as a valid contextual type
        SolidAgent::Registry.register_contextual(self)
      end

      private

      def setup_contextual_associations
        config = contextual_configuration
        
        # Set up message association if not already defined
        if config.messages_source && !method_defined?(config.messages_method)
          case config.messages_source
          when Symbol
            alias_method :contextual_messages, config.messages_source
          when Proc
            define_method :contextual_messages, &config.messages_source
          end
        end
        
        # Set up user association
        if config.user_source && !method_defined?(:contextual_user)
          case config.user_source
          when Symbol
            alias_method :contextual_user, config.user_source
          when Proc
            define_method :contextual_user, &config.user_source
          end
        end
        
        # Set up agent association
        if config.agent_source && !method_defined?(:contextual_agent)
          case config.agent_source
          when Symbol
            alias_method :contextual_agent, config.agent_source
          when Proc
            define_method :contextual_agent, &config.agent_source
          end
        end
      end
    end

    module ContextualInstanceMethods
      # Start a new prompt-generation cycle (like starting an HTTP request)
      def start_prompt_cycle(agent_class, prompt_data = {})
        cycle = prompt_generation_cycles.create!(
          agent: SolidAgent::Models::Agent.register(agent_class),
          status: "prompting",
          started_at: Time.current,
          prompt_metadata: extract_prompt_metadata(prompt_data)
        )
        
        # Track the prompt construction
        cycle.track_prompt_construction do
          yield cycle if block_given?
        end
        
        cycle
      end

      # Complete a prompt-generation cycle (like completing an HTTP response)
      def complete_generation_cycle(cycle, generation_data)
        cycle.complete_generation!(
          generation_data: generation_data,
          completed_at: Time.current
        )
      end

      # Convert to SolidAgent PromptContext
      def to_prompt_context
        SolidAgent::Models::PromptContext.new(
          contextual: self,
          context_type: contextual_type,
          messages: build_messages_array,
          metadata: build_context_metadata
        )
      end

      # Get all messages in SolidAgent format
      def to_solid_messages
        return [] unless respond_to?(:contextual_messages)
        
        contextual_messages.map.with_index do |msg, idx|
          SolidAgent::Models::Message.new(
            role: determine_message_role(msg),
            content: extract_message_content(msg),
            content_type: detect_content_type(msg),
            position: idx,
            metadata: extract_message_metadata(msg)
          )
        end
      end

      private

      def extract_prompt_metadata(prompt_data)
        {
          contextual_type: self.class.contextual_type,
          contextual_id: id,
          contextual_class: self.class.name,
          prompt_data: prompt_data,
          message_count: contextual_messages.count
        }
      end

      def build_messages_array
        return [] unless respond_to?(:contextual_messages)
        
        contextual_messages.map do |message|
          contextual_configuration.message_adapter.adapt(message)
        end
      end

      def build_context_metadata
        {
          type: contextual_type,
          id: id,
          class: self.class.name,
          created_at: created_at,
          updated_at: updated_at
        }.merge(contextual_configuration.metadata_extractor.call(self))
      end

      def determine_message_role(message)
        contextual_configuration.role_determiner.call(message)
      end

      def extract_message_content(message)
        contextual_configuration.content_extractor.call(message)
      end

      def detect_content_type(message)
        contextual_configuration.content_type_detector.call(message)
      end

      def extract_message_metadata(message)
        contextual_configuration.metadata_extractor.call(message)
      end
    end

    # Configuration class for contextual DSL
    class ContextualConfiguration
      attr_reader :model_class, :context_source, :messages_source, 
                  :user_source, :agent_source, :metadata_source

      def initialize(model_class, **options)
        @model_class = model_class
        @context_source = options[:context] || model_class
        @messages_source = options[:messages] || :messages
        @user_source = options[:user]
        @agent_source = options[:agent]
        @metadata_source = options[:metadata] || {}
        
        # Message adapters for converting to SolidAgent format
        @message_adapter = options[:message_adapter] || DefaultMessageAdapter.new
        @role_determiner = options[:role_determiner] || default_role_determiner
        @content_extractor = options[:content_extractor] || default_content_extractor
        @content_type_detector = options[:content_type_detector] || default_content_type_detector
        @metadata_extractor = options[:metadata_extractor] || default_metadata_extractor
      end

      def messages_method
        case @messages_source
        when Symbol then @messages_source
        when Proc then :contextual_messages
        else :messages
        end
      end

      attr_reader :message_adapter, :role_determiner, :content_extractor,
                  :content_type_detector, :metadata_extractor

      private

      def default_role_determiner
        ->(message) do
          if message.respond_to?(:role)
            message.role.to_s
          elsif message.respond_to?(:sender_type)
            case message.sender_type.to_s
            when "User", "Human" then "user"
            when "Assistant", "AI", "Bot" then "assistant"
            when "System" then "system"
            else "user"
            end
          elsif message.respond_to?(:from_ai?) 
            message.from_ai? ? "assistant" : "user"
          else
            "user"
          end
        end
      end

      def default_content_extractor
        ->(message) do
          if message.respond_to?(:content)
            message.content
          elsif message.respond_to?(:body)
            message.body
          elsif message.respond_to?(:text)
            message.text
          elsif message.respond_to?(:message)
            message.message
          else
            message.to_s
          end
        end
      end

      def default_content_type_detector
        ->(message) do
          content = default_content_extractor.call(message)
          case content
          when String then "text"
          when Array then "multimodal"
          when Hash then "structured"
          else "unknown"
          end
        end
      end

      def default_metadata_extractor
        ->(obj) do
          metadata = {}
          
          # Common metadata attributes
          [:created_at, :updated_at, :user_id, :session_id].each do |attr|
            metadata[attr] = obj.send(attr) if obj.respond_to?(attr)
          end
          
          # Include custom metadata method if defined
          if obj.respond_to?(:metadata)
            metadata.merge!(obj.metadata)
          end
          
          metadata
        end
      end
    end

    # Default adapter for messages
    class DefaultMessageAdapter
      def adapt(message)
        {
          role: determine_role(message),
          content: extract_content(message),
          metadata: extract_metadata(message)
        }
      end

      private

      def determine_role(message)
        # Implementation matches default_role_determiner above
      end

      def extract_content(message)
        # Implementation matches default_content_extractor above
      end

      def extract_metadata(message)
        # Implementation matches default_metadata_extractor above
      end
    end
  end
end