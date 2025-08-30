# frozen_string_literal: true

module SolidAgent
  module Models
    # region prompt-context-definition
    # PromptContext represents the full context of an agent interaction
    # including system instructions, developer directives, runtime state,
    # tool executions, and assistant responses - not just "conversations"
    class PromptContext < ActiveRecord::Base
    # endregion prompt-context-definition
      self.table_name = "#{SolidAgent.table_name_prefix}prompt_contexts"

      # Associations
      belongs_to :agent, class_name: "SolidAgent::Models::Agent"
      belongs_to :contextual, polymorphic: true, optional: true # Can be User, Process, Job, etc.
      has_many :messages, -> { order(:position) }, 
               class_name: "SolidAgent::Models::Message", 
               dependent: :destroy
      has_many :generations, class_name: "SolidAgent::Models::Generation", 
               dependent: :destroy
      has_many :evaluations, as: :evaluatable, 
               class_name: "SolidAgent::Models::Evaluation", 
               dependent: :destroy
      has_many :actions, through: :messages,
               class_name: "SolidAgent::Models::Action"

      # Validations
      validates :status, inclusion: { in: %w[active processing completed failed archived] }
      validates :context_type, inclusion: { 
        in: %w[runtime agent_context prompt_context tool_execution background_job api_request] 
      }
      validates :external_id, uniqueness: true, allow_nil: true

      # Callbacks
      before_validation :set_defaults, on: :create
      after_update :set_completed_at, if: :completed_or_failed?

      # Scopes
      scope :active, -> { where(status: "active") }
      scope :processing, -> { where(status: "processing") }
      scope :completed, -> { where(status: "completed") }
      scope :failed, -> { where(status: "failed") }
      scope :recent, -> { order(created_at: :desc) }
      scope :for_contextual, ->(contextual) { where(contextual: contextual) }
      scope :by_type, ->(type) { where(context_type: type) }

      # Class methods
      class << self
        def find_or_create_for_context(context_id, agent_class, context_type: "runtime")
          agent = Agent.register(agent_class)
          
          find_or_create_by(external_id: context_id, agent: agent) do |context|
            context.status = "active"
            context.context_type = context_type
            context.started_at = Time.current
            context.metadata = { 
              context_id: context_id,
              agent_class: agent_class.name,
              context_type: context_type
            }
          end
        end

        def create_from_prompt(prompt_object, agent_instance)
          agent = Agent.register(agent_instance.class)
          
          context = create!(
            agent: agent,
            status: "active",
            context_type: determine_context_type(prompt_object),
            started_at: Time.current,
            metadata: {
              action_name: prompt_object.action_name,
              agent_class: prompt_object.agent_class&.name,
              multimodal: prompt_object.multimodal?,
              has_actions: prompt_object.actions.any?,
              output_schema: prompt_object.output_schema.present?
            }
          )

          # Import messages from the prompt
          prompt_object.messages.each_with_index do |msg, idx|
            context.messages.create!(
              role: msg.role.to_s,
              content: serialize_content(msg.content),
              content_type: detect_content_type(msg.content),
              position: idx,
              metadata: msg.respond_to?(:metadata) ? msg.metadata : {}
            )
          end

          context
        end

        private

        def determine_context_type(prompt)
          if prompt.action_name.present?
            "tool_execution"
          elsif prompt.context_id&.include?("job")
            "background_job"
          elsif prompt.context_id&.include?("api")
            "api_request"
          else
            "runtime"
          end
        end

        def serialize_content(content)
          case content
          when String
            content
          when Array
            # Handle multimodal content
            content.to_json
          else
            content.to_s
          end
        end

        def detect_content_type(content)
          case content
          when String
            "text"
          when Array
            "multimodal"
          when Hash
            "structured"
          else
            "unknown"
          end
        end
      end

      # Instance methods
      def add_message(role:, content:, metadata: {})
        position = messages.maximum(:position).to_i + 1
        
        messages.create!(
          role: role,
          content: content,
          position: position,
          metadata: metadata
        )
      end

      def add_system_message(content, metadata = {})
        add_message(role: "system", content: content, metadata: metadata)
      end

      def add_developer_message(content, metadata = {})
        # Developer messages are a special type of system message
        add_message(
          role: "system", 
          content: content, 
          metadata: metadata.merge(source: "developer")
        )
      end

      def add_user_message(content, metadata = {})
        add_message(role: "user", content: content, metadata: metadata)
      end

      def add_assistant_message(content, requested_actions: [], metadata: {})
        message = add_message(
          role: "assistant", 
          content: content, 
          metadata: metadata.merge(requested_actions: requested_actions)
        )
        
        # Create action records for requested tool calls
        requested_actions.each do |action_data|
          message.actions.create!(
            action_name: action_data[:name] || action_data["name"],
            action_id: action_data[:id] || action_data["id"],
            parameters: action_data[:arguments] || action_data[:parameters] || action_data["arguments"],
            status: "pending"
          )
        end
        
        message
      end

      def add_tool_message(content, action_id:, metadata: {})
        message = add_message(
          role: "tool", 
          content: content, 
          metadata: metadata.merge(action_id: action_id)
        )
        
        # Mark the action as executed
        if action = Action.find_by(action_id: action_id)
          action.update!(
            status: "executed",
            executed_at: Time.current,
            result_message_id: message.id
          )
        end
        
        message
      end

      def process!
        update!(status: "processing")
      end

      def complete!
        update!(status: "completed", completed_at: Time.current)
      end

      def fail!(error_message = nil)
        update!(
          status: "failed",
          completed_at: Time.current,
          metadata: metadata.merge(error: error_message)
        )
      end

      def archive!
        update!(status: "archived")
      end

      def active?
        status == "active"
      end

      def processing?
        status == "processing"
      end

      def completed?
        status == "completed"
      end

      def failed?
        status == "failed"
      end

      def duration
        return nil unless started_at
        (completed_at || Time.current) - started_at
      end

      def total_tokens
        generations.sum(:total_tokens)
      end

      def total_cost
        generations.sum(:cost)
      end

      def message_count
        messages.count
      end

      def has_tool_calls?
        actions.any?
      end

      def pending_actions
        actions.where(status: "pending")
      end

      def executed_actions
        actions.where(status: "executed")
      end

      # Convert back to ActionPrompt::Prompt format
      def to_prompt
        ActiveAgent::ActionPrompt::Prompt.new(
          messages: messages.map(&:to_action_prompt_message),
          context_id: external_id,
          agent_class: agent.agent_class,
          actions: agent.agent_class&.action_methods || [],
          options: metadata["options"] || {}
        )
      end

      def to_prompt_messages
        messages.map(&:to_action_prompt_message)
      end

      private

      def set_defaults
        self.status ||= "active"
        self.context_type ||= "runtime"
        self.started_at ||= Time.current
        self.metadata ||= {}
      end

      def completed_or_failed?
        completed? || failed?
      end

      def set_completed_at
        update_column(:completed_at, Time.current) if completed_at.nil?
      end
    end
  end
end