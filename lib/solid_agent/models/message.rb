# frozen_string_literal: true

module SolidAgent
  module Models
    class Message < ActiveRecord::Base
      self.table_name = "#{SolidAgent.table_name_prefix}messages"

      # Associations
      belongs_to :prompt_context, class_name: "SolidAgent::Models::PromptContext"
      has_many :actions, class_name: "SolidAgent::Models::Action", dependent: :destroy
      has_one :generation, class_name: "SolidAgent::Models::Generation", dependent: :destroy
      has_many :evaluations, as: :evaluatable, 
               class_name: "SolidAgent::Models::Evaluation", 
               dependent: :destroy

      # Validations
      validates :role, inclusion: { in: %w[system user assistant tool] }
      validates :position, presence: true, numericality: { greater_than_or_equal_to: 0 }
      validates :content_type, inclusion: { 
        in: %w[text html json multimodal structured binary] 
      }

      # Callbacks
      before_validation :set_defaults, on: :create
      before_save :detect_and_set_content_type
      before_save :truncate_content_if_needed

      # Scopes
      scope :by_role, ->(role) { where(role: role) }
      scope :system_messages, -> { where(role: "system") }
      scope :user_messages, -> { where(role: "user") }
      scope :assistant_messages, -> { where(role: "assistant") }
      scope :tool_messages, -> { where(role: "tool") }
      scope :ordered, -> { order(:position) }
      scope :with_actions, -> { includes(:actions) }
      scope :developer_messages, -> { where(role: "system", "metadata->>'source'" => "developer") }

      # Instance methods
      def system?
        role == "system"
      end

      def user?
        role == "user"
      end

      def assistant?
        role == "assistant"
      end

      def tool?
        role == "tool"
      end

      def developer?
        system? && metadata["source"] == "developer"
      end

      def multimodal?
        content_type == "multimodal" || parsed_content.is_a?(Array)
      end

      def has_actions?
        actions.any? || requested_actions.any?
      end

      def requested_actions
        return [] unless assistant?
        metadata["requested_actions"] || []
      end

      def action_id
        return nil unless tool?
        metadata["action_id"]
      end

      def parsed_content
        @parsed_content ||= begin
          case content_type
          when "json", "structured", "multimodal"
            JSON.parse(content)
          else
            content
          end
        rescue JSON::ParserError
          content
        end
      end

      def text_content
        case parsed_content
        when String
          parsed_content
        when Array
          # Extract text from multimodal content
          parsed_content.map do |part|
            part["text"] || part[:text] || ""
          end.join("\n")
        when Hash
          parsed_content.to_json
        else
          content.to_s
        end
      end

      # Convert to ActiveAgent::ActionPrompt::Message format
      def to_action_prompt_message
        msg_content = case content_type
        when "multimodal"
          parsed_content
        else
          content
        end

        ActiveAgent::ActionPrompt::Message.new(
          role: role.to_sym,
          content: msg_content,
          action_id: metadata["action_id"],
          action_name: metadata["action_name"],
          requested_actions: requested_actions
        )
      end

      def to_h
        {
          role: role,
          content: parsed_content,
          position: position,
          content_type: content_type,
          metadata: metadata,
          created_at: created_at
        }
      end

      def token_count
        # Rough estimation - should be replaced with actual tokenizer
        @token_count ||= begin
          text = text_content
          (text.split(/\s+/).length * 1.3).to_i
        end
      end

      private

      def set_defaults
        self.content_type ||= "text"
        self.metadata ||= {}
      end

      def detect_and_set_content_type
        return if content_type.present? && content_type != "text"

        if content.start_with?("{", "[")
          begin
            JSON.parse(content)
            self.content_type = content.start_with?("[") ? "multimodal" : "structured"
          rescue JSON::ParserError
            # Keep as text
          end
        elsif content.match?(/<[^>]+>/)
          self.content_type = "html"
        end
      end

      def truncate_content_if_needed
        max_length = SolidAgent.configuration.max_message_length
        return unless max_length && content.length > max_length

        self.content = content[0...max_length]
        self.metadata["truncated"] = true
        self.metadata["original_length"] = content.length
      end
    end
  end
end