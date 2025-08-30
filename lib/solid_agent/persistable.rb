# frozen_string_literal: true

module SolidAgent
  # SolidAgent::Persistable - Automatic persistence for ActiveAgent
  # 
  # Just include this module and EVERYTHING is persisted automatically:
  # - Agent registrations
  # - Prompt contexts 
  # - All messages (system, user, assistant, tool)
  # - Generations and responses
  # - Tool/action executions
  # - Usage metrics and costs
  #
  # No configuration needed - it just works!
  #
  # Example:
  #   class ApplicationAgent < ActiveAgent::Base
  #     include SolidAgent::Persistable  # That's it! Full persistence enabled
  #   end
  #
  module Persistable
    extend ActiveSupport::Concern

    included do
      # Ensure persistence is enabled by default
      class_attribute :solid_agent_enabled, default: true
      
      # Prepend our automatic interceptors
      prepend AutomaticPersistence
      
      # Register this agent class on first use
      before_action :ensure_agent_registered
    end

    # region automatic-persistence
    # AutomaticPersistence intercepts ALL key methods to guarantee persistence
    # Developers never need to call these - they happen automatically
    module AutomaticPersistence
    # endregion automatic-persistence
      def prompt(*args, **options)
        # Start tracking this prompt context
        ensure_prompt_context
        
        # Let the original method run
        result = super
        
        # Persist everything about this prompt
        persist_prompt_automatically
        
        result
      end

      def generate(*args, **options)
        return super unless solid_agent_enabled
        
        # Create generation tracking record
        start_generation_tracking
        
        # Run the actual generation
        result = super
        
        # Persist the complete response
        persist_generation_response(result)
        
        result
      rescue => error
        persist_generation_error(error)
        raise
      end

      def process(action_name, *args)
        return super unless solid_agent_enabled
        
        # Track this action execution
        track_action_execution(action_name, args)
        
        super
      end

      # Intercept response handling to ensure we capture everything
      def context
        result = super
        persist_context_updates(result) if result && solid_agent_enabled
        result
      end

      private

      def ensure_agent_registered
        return unless solid_agent_enabled
        @_solid_agent ||= Models::Agent.register(self.class)
      end

      def ensure_prompt_context
        return unless solid_agent_enabled
        
        @_solid_prompt_context ||= Models::PromptContext.create!(
          agent: ensure_agent_registered,
          context_type: determine_context_type,
          status: "active",
          started_at: Time.current,
          metadata: {
            action_name: action_name,
            params: params.to_unsafe_h,
            controller_name: self.class.name
          }
        )
      end

      def start_generation_tracking
        return unless @_solid_prompt_context
        
        @_generation_start = Time.current
        @_solid_generation = @_solid_prompt_context.generations.create!(
          provider: generation_provider.to_s,
          model: extract_model_name,
          status: "processing",
          started_at: @_generation_start,
          options: generation_options
        )
      end

      def persist_prompt_automatically
        return unless @_solid_prompt_context && context&.prompt
        
        prompt_obj = context.prompt
        
        # Persist all messages from the prompt
        prompt_obj.messages.each_with_index do |msg, idx|
          persist_message(msg, idx)
        end
        
        # Store prompt metadata
        @_solid_prompt_context.update!(
          metadata: @_solid_prompt_context.metadata.merge(
            multimodal: prompt_obj.multimodal?,
            has_actions: prompt_obj.actions.present?,
            action_count: prompt_obj.actions&.size || 0,
            output_schema: prompt_obj.output_schema.present?
          )
        )
      rescue => e
        Rails.logger.error "[SolidAgent] Failed to persist prompt: #{e.message}"
      end

      def persist_generation_response(response)
        return unless @_solid_generation && response
        
        # Extract token usage and costs
        usage_data = extract_usage_data(response)
        
        @_solid_generation.complete!(usage_data)
        
        # Persist the assistant's response message
        if response.try(:message) || response.try(:content)
          persist_assistant_response(response)
        end
        
        # Track any requested actions
        if response.try(:requested_actions)&.any?
          persist_requested_actions(response.requested_actions)
        end
        
        # Update prompt context status
        @_solid_prompt_context&.complete!
        
        # Update usage metrics
        update_usage_metrics(usage_data)
      rescue => e
        Rails.logger.error "[SolidAgent] Failed to persist generation response: #{e.message}"
      end

      def persist_generation_error(error)
        @_solid_generation&.fail!(error.message)
        @_solid_prompt_context&.fail!(error.message)
      end

      def persist_message(message, position)
        return unless @_solid_prompt_context
        
        @_solid_prompt_context.messages.create!(
          role: message.role.to_s,
          content: serialize_content(message.content),
          content_type: detect_content_type(message.content),
          position: position,
          metadata: extract_message_metadata(message)
        )
      end

      def persist_assistant_response(response)
        return unless @_solid_prompt_context
        
        content = response.try(:message)&.content || response.try(:content)
        return unless content
        
        message = @_solid_prompt_context.add_assistant_message(
          content,
          requested_actions: response.try(:requested_actions) || [],
          metadata: {
            generation_id: @_solid_generation&.id,
            finish_reason: response.try(:finish_reason)
          }
        )
        
        # Link generation to message
        @_solid_generation&.update!(message_id: message.id)
      end

      def persist_requested_actions(actions)
        return unless @_solid_prompt_context
        
        # Find the assistant message that requested these actions
        assistant_message = @_solid_prompt_context.messages
                                                  .where(role: "assistant")
                                                  .order(position: :desc)
                                                  .first
        return unless assistant_message
        
        actions.each do |action|
          assistant_message.actions.create!(
            action_name: action[:name] || action["name"],
            action_id: action[:id] || action["id"], 
            parameters: action[:arguments] || action[:parameters] || action["arguments"],
            status: "pending"
          )
        end
      end

      def track_action_execution(action_name, args)
        return unless @_solid_prompt_context
        
        # Find any pending action with this name
        action = @_solid_prompt_context.actions.pending.find_by(action_name: action_name)
        
        if action
          action.execute!
          
          # Store the result after execution completes
          Thread.current[:solid_agent_current_action] = action
        end
      end

      def persist_context_updates(context)
        # Capture any tool execution results
        if Thread.current[:solid_agent_current_action]
          action = Thread.current[:solid_agent_current_action]
          Thread.current[:solid_agent_current_action] = nil
          
          # The action completed successfully
          action.complete!
        end
      end

      def determine_context_type
        case action_name.to_s
        when /tool/, /action/, /execute/
          "tool_execution"
        when /job/, /perform/
          "background_job"
        when /api/
          "api_request"
        else
          "runtime"
        end
      end

      def extract_model_name
        options[:model] || 
        generation_options[:model] || 
        self.class.generation_provider_options[:model] ||
        "unknown"
      end

      def generation_options
        options.except(:model, :provider).merge(
          temperature: options[:temperature],
          max_tokens: options[:max_tokens]
        ).compact
      end

      def extract_usage_data(response)
        {
          prompt_tokens: response.try(:prompt_tokens) || response.try(:usage)&.dig(:prompt_tokens),
          completion_tokens: response.try(:completion_tokens) || response.try(:usage)&.dig(:completion_tokens),
          total_tokens: response.try(:total_tokens) || response.try(:usage)&.dig(:total_tokens),
          finish_reason: response.try(:finish_reason)
        }.compact
      end

      def update_usage_metrics(usage_data)
        return unless @_solid_agent && usage_data[:total_tokens]
        
        date = Date.current
        metric = Models::UsageMetric.find_or_create_by(
          agent: @_solid_agent,
          date: date,
          provider: @_solid_generation.provider,
          model: @_solid_generation.model
        )
        
        metric.increment!(:total_requests)
        metric.increment!(:total_tokens, usage_data[:total_tokens])
        
        if @_solid_generation.cost
          metric.increment!(:total_cost, @_solid_generation.cost)
        end
      end

      def serialize_content(content)
        case content
        when String
          content
        when Array, Hash
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

      def extract_message_metadata(message)
        metadata = {}
        
        metadata[:action_id] = message.action_id if message.respond_to?(:action_id)
        metadata[:action_name] = message.action_name if message.respond_to?(:action_name)
        metadata[:requested_actions] = message.requested_actions if message.respond_to?(:requested_actions)
        
        metadata
      end
    end
  end
end