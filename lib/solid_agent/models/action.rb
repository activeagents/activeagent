# frozen_string_literal: true

module SolidAgent
  module Models
    class Action < ActiveRecord::Base
      self.table_name = "#{SolidAgent.table_name_prefix}actions"

      # Associations
      belongs_to :message, class_name: "SolidAgent::Models::Message"
      belongs_to :result_message, class_name: "SolidAgent::Models::Message", 
                 optional: true, foreign_key: :result_message_id
      has_one :prompt_context, through: :message

      # Validations
      validates :action_name, presence: true
      validates :action_id, presence: true, uniqueness: true
      validates :status, inclusion: { 
        in: %w[pending executing executed failed cancelled] 
      }

      # Callbacks
      before_validation :set_defaults, on: :create
      before_validation :generate_action_id, on: :create

      # Scopes
      scope :pending, -> { where(status: "pending") }
      scope :executing, -> { where(status: "executing") }
      scope :executed, -> { where(status: "executed") }
      scope :failed, -> { where(status: "failed") }
      scope :recent, -> { order(created_at: :desc) }

      # Instance methods
      def execute!
        update!(status: "executing", executed_at: Time.current)
      end

      def complete!(result_message_id = nil)
        update!(
          status: "executed",
          result_message_id: result_message_id,
          completed_at: Time.current,
          latency_ms: calculate_latency
        )
      end

      def fail!(error_message = nil)
        update!(
          status: "failed",
          completed_at: Time.current,
          latency_ms: calculate_latency,
          metadata: metadata.merge(error: error_message)
        )
      end

      def cancel!
        update!(status: "cancelled")
      end

      def pending?
        status == "pending"
      end

      def executing?
        status == "executing"
      end

      def executed?
        status == "executed"
      end

      def failed?
        status == "failed"
      end

      def cancelled?
        status == "cancelled"
      end

      def success?
        executed?
      end

      def duration
        return nil unless executed_at
        (completed_at || Time.current) - executed_at
      end

      def to_h
        {
          id: action_id,
          name: action_name,
          arguments: parameters,
          status: status
        }
      end

      private

      def set_defaults
        self.status ||= "pending"
        self.parameters ||= {}
        self.metadata ||= {}
      end

      def generate_action_id
        self.action_id ||= "call_#{SecureRandom.hex(12)}"
      end

      def calculate_latency
        return nil unless executed_at
        ((Time.current - executed_at) * 1000).to_i
      end
    end
  end
end