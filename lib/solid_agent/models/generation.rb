# frozen_string_literal: true

module SolidAgent
  module Models
    class Generation < ActiveRecord::Base
      self.table_name = "#{SolidAgent.table_name_prefix}generations"

      # Associations
      belongs_to :prompt_context, class_name: "SolidAgent::Models::PromptContext"
      belongs_to :message, class_name: "SolidAgent::Models::Message", optional: true
      belongs_to :prompt_version, class_name: "SolidAgent::Models::PromptVersion", optional: true
      has_many :evaluations, as: :evaluatable, 
               class_name: "SolidAgent::Models::Evaluation", 
               dependent: :destroy

      # Validations
      validates :provider, presence: true
      validates :model, presence: true
      validates :status, inclusion: { 
        in: %w[pending processing completed failed cancelled] 
      }

      # Callbacks
      before_validation :set_defaults, on: :create
      after_update :calculate_cost, if: :tokens_changed?

      # Scopes
      scope :completed, -> { where(status: "completed") }
      scope :failed, -> { where(status: "failed") }
      scope :recent, -> { order(created_at: :desc) }
      scope :by_provider, ->(provider) { where(provider: provider) }
      scope :by_model, ->(model) { where(model: model) }
      scope :with_latency, -> { where.not(latency_ms: nil) }

      # Class methods
      class << self
        def average_latency
          with_latency.average(:latency_ms)
        end

        def total_cost
          sum(:cost)
        end

        def total_tokens
          sum(:total_tokens)
        end

        def success_rate
          total = count
          return 0.0 if total.zero?
          
          (completed.count.to_f / total * 100).round(2)
        end
      end

      # Instance methods
      def start!
        update!(
          status: "processing",
          started_at: Time.current
        )
      end

      def complete!(response_data = {})
        update!(
          status: "completed",
          completed_at: Time.current,
          latency_ms: calculate_latency,
          prompt_tokens: response_data[:prompt_tokens],
          completion_tokens: response_data[:completion_tokens],
          total_tokens: response_data[:total_tokens] || 
                       (response_data[:prompt_tokens].to_i + response_data[:completion_tokens].to_i),
          metadata: metadata.merge(response_data.except(:prompt_tokens, :completion_tokens, :total_tokens))
        )
      end

      def fail!(error_message)
        update!(
          status: "failed",
          completed_at: Time.current,
          error_message: error_message,
          latency_ms: calculate_latency
        )
      end

      def cancel!
        update!(status: "cancelled")
      end

      def pending?
        status == "pending"
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

      def cancelled?
        status == "cancelled"
      end

      def success?
        completed?
      end

      def duration
        return nil unless started_at
        (completed_at || Time.current) - started_at
      end

      def cost_per_token
        return 0 if total_tokens.to_i.zero?
        cost.to_f / total_tokens
      end

      private

      def set_defaults
        self.status ||= "pending"
        self.metadata ||= {}
        self.options ||= {}
        self.prompt_tokens ||= 0
        self.completion_tokens ||= 0
        self.total_tokens ||= 0
        self.cost ||= 0.0
      end

      def calculate_latency
        return nil unless started_at
        ((Time.current - started_at) * 1000).to_i
      end

      def tokens_changed?
        saved_change_to_prompt_tokens? || 
        saved_change_to_completion_tokens? || 
        saved_change_to_total_tokens?
      end

      def calculate_cost
        return unless provider && model

        # Cost calculation based on provider and model
        # This should be extracted to a service or configuration
        costs = {
          "openai" => {
            "gpt-4" => { prompt: 0.03, completion: 0.06 },
            "gpt-4-turbo" => { prompt: 0.01, completion: 0.03 },
            "gpt-3.5-turbo" => { prompt: 0.0005, completion: 0.0015 },
            "gpt-4o" => { prompt: 0.005, completion: 0.015 },
            "gpt-4o-mini" => { prompt: 0.00015, completion: 0.0006 }
          },
          "anthropic" => {
            "claude-3-opus" => { prompt: 0.015, completion: 0.075 },
            "claude-3-sonnet" => { prompt: 0.003, completion: 0.015 },
            "claude-3-haiku" => { prompt: 0.00025, completion: 0.00125 },
            "claude-3.5-sonnet" => { prompt: 0.003, completion: 0.015 }
          }
        }

        provider_costs = costs[provider.downcase]
        return unless provider_costs

        model_costs = provider_costs[model.downcase] || provider_costs[model.split("-")[0..1].join("-")]
        return unless model_costs

        prompt_cost = (prompt_tokens.to_i / 1000.0) * model_costs[:prompt]
        completion_cost = (completion_tokens.to_i / 1000.0) * model_costs[:completion]
        
        update_column(:cost, (prompt_cost + completion_cost).round(6))
      end
    end
  end
end