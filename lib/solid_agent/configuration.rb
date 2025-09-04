# frozen_string_literal: true

module SolidAgent
  class Configuration
    attr_accessor :auto_persist, :persist_in_background, :retention_days,
                  :batch_size, :async_processor, :redact_sensitive_data,
                  :encryption_key, :table_name_prefix, :persist_system_messages,
                  :max_message_length, :enable_evaluations, :evaluation_queue

    def initialize
      @auto_persist = true
      @persist_in_background = true
      @retention_days = 90
      @batch_size = 100
      @async_processor = :sidekiq
      @redact_sensitive_data = false
      @encryption_key = nil
      @table_name_prefix = "solid_agent_"
      @persist_system_messages = true
      @max_message_length = 100_000
      @enable_evaluations = false
      @evaluation_queue = :default
    end

    def async_processor_class
      case async_processor
      when :sidekiq
        require "sidekiq"
        "SolidAgent::Jobs::SidekiqProcessor"
      when :good_job
        require "good_job"
        "SolidAgent::Jobs::GoodJobProcessor"
      when :solid_queue
        "SolidAgent::Jobs::SolidQueueProcessor"
      else
        "SolidAgent::Jobs::InlineProcessor"
      end
    end
  end
end