# frozen_string_literal: true

# SolidAgent Configuration
# This file configures the SolidAgent persistence layer for ActiveAgent
# SolidAgent provides ActiveRecord-based persistence for prompts, contexts,
# messages, generations, and usage metrics.

SolidAgent.configure do |config|
  # === Persistence Settings ===
  
  # Automatically persist prompt contexts and generations
  # Set to false to disable automatic persistence
  config.auto_persist = Rails.env.production?
  
  # Process persistence in background jobs
  # When true, persistence happens asynchronously via your job processor
  config.persist_in_background = Rails.env.production?
  
  # Data retention period in days
  # Older data will be archived or deleted based on your retention policy
  config.retention_days = 90
  
  # === Performance Settings ===
  
  # Batch size for bulk operations
  config.batch_size = 100
  
  # Background job processor (:sidekiq, :good_job, :solid_queue, :inline)
  config.async_processor = :sidekiq
  
  # === Privacy & Security Settings ===
  
  # Redact sensitive information from persisted data
  # When true, PII and sensitive data will be masked
  config.redact_sensitive_data = Rails.env.production?
  
  # Encryption key for sensitive data (optional)
  # If provided, sensitive fields will be encrypted at rest
  # config.encryption_key = Rails.application.credentials.solid_agent_encryption_key
  
  # === Storage Settings ===
  
  # Database table prefix
  # All SolidAgent tables will use this prefix
  config.table_name_prefix = "solid_agent_"
  
  # Persist system messages
  # When false, system/instruction messages won't be stored
  config.persist_system_messages = true
  
  # Maximum message content length
  # Messages longer than this will be truncated
  config.max_message_length = 100_000
  
  # === Evaluation Settings ===
  
  # Enable evaluation tracking
  # When true, allows storing quality metrics and feedback
  config.enable_evaluations = Rails.env.development? || Rails.env.staging?
  
  # Queue for evaluation jobs
  config.evaluation_queue = :low_priority
end

# === ActiveAgent Integration ===
# To enable persistence for all agents, add to ApplicationAgent:
#
# class ApplicationAgent < ActiveAgent::Base
#   include SolidAgent::Persistable
#   
#   solid_agent do
#     track_prompts true
#     store_generations true
#     version_prompts Rails.env.production?
#     enable_evaluations Rails.env.staging?
#   end
# end

# === ActiveSupervisor Integration (Optional) ===
# If using ActiveSupervisor for monitoring:
#
# if defined?(ActiveSupervisor)
#   ActiveSupervisor.configure do |config|
#     config.api_key = Rails.application.credentials.active_supervisor_api_key
#     config.environment = Rails.env
#     config.application_name = Rails.application.class.module_parent_name
#   end
# end