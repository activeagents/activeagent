# frozen_string_literal: true

module SolidAgent
  module Models
    # PromptGenerationCycle tracks the complete Request-Response cycle
    # Similar to HTTP Request-Response, but for AI: Prompt-Generation
    # This is the atomic unit that ActiveSupervisor monitors
    class PromptGenerationCycle < ActiveRecord::Base
      self.table_name = "#{SolidAgent.table_name_prefix}prompt_generation_cycles"

      # Associations
      belongs_to :contextual, polymorphic: true  # The Chat, Conversation, etc.
      belongs_to :agent, class_name: "SolidAgent::Models::Agent"
      belongs_to :prompt_context, class_name: "SolidAgent::Models::PromptContext", optional: true
      has_one :generation, class_name: "SolidAgent::Models::Generation", dependent: :destroy
      has_many :evaluations, as: :evaluatable, 
               class_name: "SolidAgent::Models::Evaluation", 
               dependent: :destroy

      # Validations
      validates :status, inclusion: { 
        in: %w[prompting generating completed failed cancelled timeout] 
      }
      validates :cycle_id, presence: true, uniqueness: true

      # Callbacks
      before_validation :generate_cycle_id, on: :create
      after_update :calculate_metrics, if: :completed_or_failed?

      # Scopes
      scope :completed, -> { where(status: "completed") }
      scope :failed, -> { where(status: ["failed", "timeout"]) }
      scope :active, -> { where(status: ["prompting", "generating"]) }
      scope :recent, -> { order(started_at: :desc) }
      scope :slow, ->(threshold_ms = 5000) { where("latency_ms > ?", threshold_ms) }
      scope :expensive, ->(threshold = 0.10) { where("cost > ?", threshold) }

      # State machine for cycle lifecycle
      def start_prompting!
        update!(
          status: "prompting",
          prompt_started_at: Time.current
        )
      end

      def start_generating!
        update!(
          status: "generating",
          generation_started_at: Time.current,
          prompt_latency_ms: calculate_prompt_latency
        )
      end

      def complete!(generation_data = {})
        update!(
          status: "completed",
          completed_at: Time.current,
          generation_latency_ms: calculate_generation_latency,
          latency_ms: calculate_total_latency,
          prompt_tokens: generation_data[:prompt_tokens],
          completion_tokens: generation_data[:completion_tokens],
          total_tokens: generation_data[:total_tokens],
          cost: generation_data[:cost],
          response_metadata: generation_data.except(:prompt_tokens, :completion_tokens, :total_tokens, :cost)
        )
      end

      def fail!(error_message, error_type = "error")
        update!(
          status: "failed",
          completed_at: Time.current,
          error_message: error_message,
          error_type: error_type,
          latency_ms: calculate_total_latency
        )
      end

      def timeout!
        fail!("Request timed out", "timeout")
        update!(status: "timeout")
      end

      def cancel!
        update!(
          status: "cancelled",
          completed_at: Time.current
        )
      end

      # region cycle-tracking
      # Track prompt construction phase
      def track_prompt_construction
        start_prompting!
        
        yield self if block_given?
        
        # Capture prompt snapshot
        capture_prompt_snapshot
      end

      # Track generation phase
      def track_generation
      # endregion cycle-tracking
        start_generating!
        
        result = yield self if block_given?
        
        # Capture generation result
        capture_generation_result(result)
        
        result
      rescue => e
        fail!(e.message)
        raise
      end

      # Complete the full cycle with generation data
      def complete_generation!(generation_data)
        complete!(extract_generation_metrics(generation_data))
        
        # Create generation record if needed
        if generation_data[:generation_id]
          self.generation = Generation.find(generation_data[:generation_id])
        end
      end

      # Metrics and monitoring
      def prompting?
        status == "prompting"
      end

      def generating?
        status == "generating"
      end

      def completed?
        status == "completed"
      end

      def failed?
        status == "failed"
      end

      def timeout?
        status == "timeout"
      end

      def success?
        completed?
      end

      def in_progress?
        prompting? || generating?
      end

      # Latency metrics
      def prompt_duration
        return nil unless prompt_started_at
        (generation_started_at || Time.current) - prompt_started_at
      end

      def generation_duration
        return nil unless generation_started_at
        (completed_at || Time.current) - generation_started_at
      end

      def total_duration
        return nil unless started_at
        (completed_at || Time.current) - started_at
      end

      # Cost metrics
      def cost_per_token
        return 0 if total_tokens.to_i.zero?
        cost.to_f / total_tokens
      end

      def prompt_cost
        return 0 unless prompt_tokens && cost_per_token > 0
        prompt_tokens * cost_per_token * 0.4  # Prompt tokens usually cheaper
      end

      def completion_cost
        return 0 unless completion_tokens && cost_per_token > 0
        completion_tokens * cost_per_token
      end

      # For ActiveSupervisor monitoring
      def to_monitoring_event
        {
          cycle_id: cycle_id,
          contextual_type: contextual_type,
          contextual_id: contextual_id,
          agent: agent.class_name,
          status: status,
          started_at: started_at,
          completed_at: completed_at,
          latency: {
            prompt_ms: prompt_latency_ms,
            generation_ms: generation_latency_ms,
            total_ms: latency_ms
          },
          tokens: {
            prompt: prompt_tokens,
            completion: completion_tokens,
            total: total_tokens
          },
          cost: {
            amount: cost,
            per_token: cost_per_token,
            currency: "USD"
          },
          error: error_message.present? ? {
            message: error_message,
            type: error_type
          } : nil
        }.compact
      end

      # Snapshot management
      def capture_prompt_snapshot
        return unless prompt_context

        update!(
          prompt_snapshot: {
            messages_count: prompt_context.messages.count,
            message_roles: prompt_context.messages.pluck(:role).tally,
            has_tools: prompt_context.actions.any?,
            tool_count: prompt_context.actions.count,
            multimodal: prompt_context.messages.any?(&:multimodal?),
            context_type: prompt_context.context_type
          }
        )
      end

      def capture_generation_result(result)
        return unless result

        update!(
          response_snapshot: {
            has_content: result.try(:content).present?,
            has_tool_calls: result.try(:requested_actions)&.any?,
            tool_calls_count: result.try(:requested_actions)&.size || 0,
            finish_reason: result.try(:finish_reason),
            response_length: result.try(:content)&.length || 0
          }
        )
      end

      private

      def generate_cycle_id
        self.cycle_id ||= "cycle_#{SecureRandom.uuid}"
      end

      def calculate_prompt_latency
        return nil unless prompt_started_at
        ((generation_started_at || Time.current) - prompt_started_at) * 1000
      end

      def calculate_generation_latency
        return nil unless generation_started_at
        ((completed_at || Time.current) - generation_started_at) * 1000
      end

      def calculate_total_latency
        return nil unless started_at
        ((completed_at || Time.current) - started_at) * 1000
      end

      def completed_or_failed?
        completed? || failed?
      end

      def calculate_metrics
        # This could trigger metric aggregation
        if completed?
          UpdateUsageMetricsJob.perform_later(self)
        end
      end

      def extract_generation_metrics(data)
        {
          prompt_tokens: data[:prompt_tokens] || data.dig(:usage, :prompt_tokens),
          completion_tokens: data[:completion_tokens] || data.dig(:usage, :completion_tokens),
          total_tokens: data[:total_tokens] || data.dig(:usage, :total_tokens),
          cost: calculate_cost(data),
          finish_reason: data[:finish_reason]
        }.compact
      end

      def calculate_cost(data)
        # Delegate to generation model or service
        return data[:cost] if data[:cost]
        
        return 0 unless agent && data[:total_tokens]
        
        # This would look up pricing based on provider/model
        SolidAgent::CostCalculator.calculate(
          provider: agent.metadata["provider"],
          model: data[:model],
          tokens: data
        )
      end
    end
  end
end