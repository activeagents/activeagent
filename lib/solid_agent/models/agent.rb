# frozen_string_literal: true

module SolidAgent
  module Models
    class Agent < ActiveRecord::Base
      self.table_name = "#{SolidAgent.table_name_prefix}agents"

      # Associations
      has_many :agent_configs, class_name: "SolidAgent::Models::AgentConfig", dependent: :destroy
      has_many :prompts, class_name: "SolidAgent::Models::Prompt", dependent: :destroy
      has_many :conversations, class_name: "SolidAgent::Models::Conversation", dependent: :destroy
      has_many :usage_metrics, class_name: "SolidAgent::Models::UsageMetric", dependent: :destroy

      # Validations
      validates :class_name, presence: true, uniqueness: true
      validates :status, inclusion: { in: %w[active inactive deprecated] }

      # Scopes
      scope :active, -> { where(status: "active") }
      scope :with_metrics, -> { includes(:usage_metrics) }

      # Class methods
      class << self
        def register(agent_class)
          class_name = agent_class.is_a?(Class) ? agent_class.name : agent_class.to_s
          
          find_or_create_by(class_name: class_name) do |agent|
            agent.display_name = class_name.demodulize.titleize
            agent.description = "#{class_name} agent"
            agent.status = "active"
            agent.metadata = extract_metadata(agent_class)
          end
        end

        def for_class(agent_class)
          class_name = agent_class.is_a?(Class) ? agent_class.name : agent_class.to_s
          find_by(class_name: class_name)
        end

        private

        def extract_metadata(agent_class)
          return {} unless agent_class.is_a?(Class)
          
          {
            provider: agent_class.generation_provider.to_s,
            actions: agent_class.action_methods.to_a,
            version: agent_class.const_defined?(:VERSION) ? agent_class::VERSION : nil
          }
        rescue StandardError => e
          Rails.logger.error "Failed to extract metadata for #{agent_class}: #{e.message}"
          {}
        end
      end

      # Instance methods
      def agent_class
        @agent_class ||= class_name.constantize
      rescue NameError
        nil
      end

      def active?
        status == "active"
      end

      def total_conversations
        conversations.count
      end

      def total_generations
        conversations.joins(:generations).count
      end

      def total_cost
        usage_metrics.sum(:total_cost)
      end

      def average_latency
        generations = Generation.joins(:conversation)
                               .where(conversations: { agent_id: id })
                               .where.not(latency_ms: nil)
        
        return 0 if generations.empty?
        generations.average(:latency_ms).to_i
      end

      def error_rate
        total = conversations.joins(:generations).count
        return 0.0 if total.zero?
        
        errors = conversations.joins(:generations)
                             .where(generations: { status: "error" })
                             .count
        
        (errors.to_f / total * 100).round(2)
      end
    end
  end
end