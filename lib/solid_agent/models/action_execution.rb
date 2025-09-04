# frozen_string_literal: true

module SolidAgent
  module Models
    # ActionExecution tracks ALL types of tool/action executions
    # Including: graph retrieval, web search, browser control, computer use, MCP, custom tools
    class ActionExecution < ActiveRecord::Base
      self.table_name = "#{SolidAgent.table_name_prefix}action_executions"

      # Core associations
      belongs_to :message, class_name: "SolidAgent::Models::Message"
      belongs_to :prompt_generation_cycle, 
                 class_name: "SolidAgent::Models::PromptGenerationCycle",
                 optional: true
      has_one :result_message, 
              class_name: "SolidAgent::Models::Message",
              foreign_key: :action_execution_id
      has_many :action_artifacts,
               class_name: "SolidAgent::Models::ActionArtifact",
               dependent: :destroy

      # Polymorphic association for action-specific data
      belongs_to :executable, polymorphic: true, optional: true

      # region action-types
      # Validations
      validates :action_type, inclusion: { 
        in: %w[
          tool function mcp_tool graph_retrieval web_search web_browse 
          computer_use api_call database_query file_operation code_execution
          image_generation audio_processing video_processing embedding_generation
          memory_retrieval memory_storage workflow_step custom
        ] 
      }
      # endregion action-types
      validates :status, inclusion: { 
        in: %w[pending queued executing executed failed cancelled timeout partial] 
      }
      validates :action_id, presence: true, uniqueness: true

      # Callbacks
      before_validation :set_defaults, on: :create
      after_update :track_execution_metrics, if: :status_changed?

      # Scopes
      scope :by_type, ->(type) { where(action_type: type) }
      scope :pending, -> { where(status: "pending") }
      scope :executed, -> { where(status: "executed") }
      scope :failed, -> { where(status: ["failed", "timeout"]) }
      scope :tool_calls, -> { where(action_type: ["tool", "function"]) }
      scope :mcp_calls, -> { where(action_type: "mcp_tool") }
      scope :retrieval_actions, -> { where(action_type: ["graph_retrieval", "memory_retrieval"]) }
      scope :web_actions, -> { where(action_type: ["web_search", "web_browse"]) }
      scope :computer_actions, -> { where(action_type: "computer_use") }

      # Action type detection
      def self.detect_action_type(action_data)
        case action_data
        when Hash
          if action_data[:mcp_server].present?
            "mcp_tool"
          elsif action_data[:graph_query].present?
            "graph_retrieval"
          elsif action_data[:web_search].present? || action_data[:query].present?
            "web_search"
          elsif action_data[:browser_action].present?
            "web_browse"
          elsif action_data[:computer_action].present?
            "computer_use"
          elsif action_data[:function].present?
            "function"
          else
            "tool"
          end
        else
          "custom"
        end
      end

      # Execution lifecycle
      def queue!
        update!(status: "queued", queued_at: Time.current)
      end

      def execute!
        update!(
          status: "executing",
          executed_at: Time.current
        )
      end

      def complete!(result_data = {})
        update!(
          status: "executed",
          completed_at: Time.current,
          latency_ms: calculate_latency,
          result_summary: extract_result_summary(result_data),
          result_metadata: result_data
        )
        
        # Store artifacts if present
        store_artifacts(result_data[:artifacts]) if result_data[:artifacts]
      end

      def fail!(error_message, error_details = {})
        update!(
          status: "failed",
          completed_at: Time.current,
          latency_ms: calculate_latency,
          error_message: error_message,
          error_details: error_details
        )
      end

      def timeout!(timeout_ms = nil)
        update!(
          status: "timeout",
          completed_at: Time.current,
          latency_ms: timeout_ms || calculate_latency,
          error_message: "Action execution timed out"
        )
      end

      def partial_complete!(partial_result)
        update!(
          status: "partial",
          partial_results: (partial_results || []) + [partial_result],
          last_activity_at: Time.current
        )
      end

      # Specific action type handlers
      def handle_graph_retrieval
        GraphRetrievalHandler.new(self).execute
      end

      def handle_web_search
        WebSearchHandler.new(self).execute
      end

      def handle_web_browse
        WebBrowseHandler.new(self).execute
      end

      def handle_computer_use
        ComputerUseHandler.new(self).execute
      end

      def handle_mcp_tool
        MCPToolHandler.new(self).execute
      end

      # Monitoring and metrics
      def execution_time
        return nil unless executed_at
        (completed_at || Time.current) - executed_at
      end

      def total_time
        return nil unless created_at
        (completed_at || Time.current) - created_at
      end

      def success?
        status == "executed"
      end

      def failed?
        ["failed", "timeout", "cancelled"].include?(status)
      end

      def in_progress?
        ["queued", "executing"].include?(status)
      end

      # Cost tracking for external services
      def calculate_cost
        case action_type
        when "web_search"
          calculate_search_cost
        when "computer_use"
          calculate_compute_cost
        when "mcp_tool"
          calculate_mcp_cost
        else
          0
        end
      end

      # For ActiveSupervisor monitoring
      def to_monitoring_event
        {
          action_id: action_id,
          action_type: action_type,
          action_name: action_name,
          status: status,
          latency_ms: latency_ms,
          created_at: created_at,
          executed_at: executed_at,
          completed_at: completed_at,
          parameters: sanitized_parameters,
          result_summary: result_summary,
          error: error_message,
          cost: calculate_cost,
          artifacts_count: action_artifacts.count
        }
      end

      private

      def set_defaults
        self.action_id ||= "action_#{SecureRandom.uuid}"
        self.status ||= "pending"
        self.parameters ||= {}
        self.result_metadata ||= {}
        self.action_type ||= self.class.detect_action_type(parameters)
      end

      def calculate_latency
        return nil unless executed_at
        ((completed_at || Time.current) - executed_at) * 1000
      end

      def extract_result_summary(result_data)
        case action_type
        when "graph_retrieval"
          "Retrieved #{result_data[:nodes_count]} nodes, #{result_data[:edges_count]} edges"
        when "web_search"
          "Found #{result_data[:results_count]} results"
        when "web_browse"
          "Navigated to #{result_data[:url]}"
        when "computer_use"
          "Executed #{result_data[:action]} action"
        when "mcp_tool"
          "Called #{result_data[:tool_name]} on #{result_data[:server]}"
        else
          result_data[:summary] || "Action completed"
        end
      end

      def store_artifacts(artifacts)
        artifacts.each do |artifact|
          action_artifacts.create!(
            artifact_type: artifact[:type],
            artifact_data: artifact[:data],
            metadata: artifact[:metadata]
          )
        end
      end

      def sanitized_parameters
        # Remove sensitive data from parameters
        parameters.except("api_key", "token", "password", "secret")
      end

      def track_execution_metrics
        return unless completed_at

        # Update daily metrics
        SolidAgent::Models::ActionMetric.track(
          action_type: action_type,
          success: success?,
          latency_ms: latency_ms,
          cost: calculate_cost
        )
      end

      def calculate_search_cost
        # Example: $0.002 per search
        0.002
      end

      def calculate_compute_cost
        # Example: $0.01 per minute of compute
        return 0 unless execution_time
        (execution_time / 60.0) * 0.01
      end

      def calculate_mcp_cost
        # Depends on the MCP server and tool
        parameters.dig(:mcp_server_config, :cost_per_call) || 0
      end
    end

    # Action artifacts for storing results
    class ActionArtifact < ActiveRecord::Base
      self.table_name = "#{SolidAgent.table_name_prefix}action_artifacts"

      belongs_to :action_execution

      validates :artifact_type, inclusion: {
        in: %w[
          text json xml html image audio video file 
          graph_data search_results screenshot 
          browser_state memory_snapshot code_output
        ]
      }

      # Store large artifacts in object storage
      has_one_attached :file if defined?(ActiveStorage)

      def size
        if file&.attached?
          file.byte_size
        elsif artifact_data.present?
          artifact_data.to_s.bytesize
        else
          0
        end
      end
    end

    # Metrics tracking for actions
    class ActionMetric < ActiveRecord::Base
      self.table_name = "#{SolidAgent.table_name_prefix}action_metrics"

      class << self
        def track(action_type:, success:, latency_ms:, cost:)
          date = Date.current
          metric = find_or_create_by(
            date: date,
            action_type: action_type
          )

          metric.increment!(:total_count)
          metric.increment!(:success_count) if success
          metric.increment!(:total_latency_ms, latency_ms || 0)
          metric.increment!(:total_cost, cost || 0)

          # Update averages
          metric.update!(
            avg_latency_ms: metric.total_latency_ms.to_f / metric.total_count,
            success_rate: (metric.success_count.to_f / metric.total_count * 100).round(2)
          )
        end
      end
    end
  end
end