# frozen_string_literal: true

module ActiveSupervisorClient
  # Trackable module that integrates with SolidAgent to automatically
  # send monitoring data to ActiveSupervisor (cloud or self-hosted)
  module Trackable
    extend ActiveSupport::Concern

    included do
      # Only add callbacks if SolidAgent is present
      if defined?(SolidAgent) && ancestors.include?(SolidAgent::Persistable)
        after_action :track_to_supervisor
        after_generation :track_generation_to_supervisor
      end
    end

    private

    def track_to_supervisor
      return unless supervisor_tracking_enabled?
      return if should_ignore_agent?
      
      # Sample based on configured rate
      return unless rand <= ActiveSupervisorClient.configuration.sample_rate
      
      # Track the prompt-generation cycle
      if @_prompt_generation_cycle
        ActiveSupervisorClient.track_prompt_cycle(
          build_cycle_payload(@_prompt_generation_cycle)
        )
      end
      
      # Track action executions
      if @_current_action
        ActiveSupervisorClient.track_action_execution(
          build_action_payload(@_current_action)
        )
      end
    rescue => e
      handle_tracking_error(e)
    end

    def track_generation_to_supervisor
      return unless supervisor_tracking_enabled?
      return unless @_solid_generation
      
      ActiveSupervisorClient.track_generation(
        build_generation_payload(@_solid_generation)
      )
    rescue => e
      handle_tracking_error(e)
    end

    def supervisor_tracking_enabled?
      ActiveSupervisorClient.configuration.enabled &&
      ActiveSupervisorClient.configuration.valid? &&
      solid_agent_enabled
    end

    def should_ignore_agent?
      ActiveSupervisorClient.configuration.ignored_agents.include?(self.class.name)
    end

    def should_ignore_action?
      ActiveSupervisorClient.configuration.ignored_actions.include?(action_name.to_s)
    end

    def build_cycle_payload(cycle)
      {
        cycle_id: cycle.cycle_id,
        agent: self.class.name,
        action: action_name.to_s,
        status: cycle.status,
        started_at: cycle.started_at&.iso8601,
        completed_at: cycle.completed_at&.iso8601,
        latency_ms: cycle.latency_ms,
        tokens: {
          prompt: cycle.prompt_tokens,
          completion: cycle.completion_tokens,
          total: cycle.total_tokens
        },
        cost: cycle.cost,
        metadata: sanitize_metadata(cycle.metadata),
        contextual: build_contextual_data(cycle.contextual),
        environment: ActiveSupervisorClient.configuration.environment,
        application: ActiveSupervisorClient.configuration.application_name
      }.compact
    end

    def build_generation_payload(generation)
      {
        generation_id: generation.id,
        provider: generation.provider,
        model: generation.model,
        status: generation.status,
        tokens: {
          prompt: generation.prompt_tokens,
          completion: generation.completion_tokens,
          total: generation.total_tokens
        },
        cost: generation.cost,
        latency_ms: generation.latency_ms,
        error: generation.error_message,
        created_at: generation.created_at.iso8601
      }.compact
    end

    def build_action_payload(action)
      {
        action_id: action.action_id,
        action_type: action.action_type,
        action_name: action.action_name,
        status: action.status,
        latency_ms: action.latency_ms,
        parameters: sanitize_parameters(action.parameters),
        result_summary: action.result_summary,
        error: action.error_message,
        created_at: action.created_at.iso8601
      }.compact
    end

    def build_contextual_data(contextual)
      return nil unless contextual
      
      {
        type: contextual.class.name,
        id: contextual.id,
        attributes: extract_safe_attributes(contextual)
      }
    end

    def sanitize_metadata(metadata)
      return {} unless metadata
      
      if ActiveSupervisorClient.configuration.pii_masking
        mask_pii(metadata)
      else
        metadata
      end
    end

    def sanitize_parameters(params)
      return {} unless params
      
      # Remove sensitive keys
      params.except(
        "password", "token", "api_key", "secret",
        "credit_card", "ssn", "email", "phone"
      )
    end

    def mask_pii(data)
      return data unless data.is_a?(Hash)
      
      data.transform_values do |value|
        case value
        when String
          mask_sensitive_string(value)
        when Hash
          mask_pii(value)
        when Array
          value.map { |v| v.is_a?(Hash) ? mask_pii(v) : v }
        else
          value
        end
      end
    end

    def mask_sensitive_string(str)
      # Email masking
      str = str.gsub(/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/, "[EMAIL]")
      
      # Phone masking
      str = str.gsub(/\b\d{3}[-.]?\d{3}[-.]?\d{4}\b/, "[PHONE]")
      
      # SSN masking
      str = str.gsub(/\b\d{3}-\d{2}-\d{4}\b/, "[SSN]")
      
      # Credit card masking
      str = str.gsub(/\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/, "[CARD]")
      
      str
    end

    def extract_safe_attributes(object)
      # Extract only safe, non-sensitive attributes
      attrs = {}
      
      [:id, :created_at, :updated_at, :status, :type].each do |attr|
        attrs[attr] = object.send(attr) if object.respond_to?(attr)
      end
      
      attrs
    end

    def handle_tracking_error(error)
      if ActiveSupervisorClient.configuration.error_handler
        ActiveSupervisorClient.configuration.error_handler.call(error)
      else
        Rails.logger.error "[ActiveSupervisor] Tracking error: #{error.message}"
      end
    end
  end
end