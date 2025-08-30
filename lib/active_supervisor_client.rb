# frozen_string_literal: true

require "active_supervisor_client/version"
require "active_supervisor_client/configuration"
require "active_supervisor_client/client"
require "active_supervisor_client/trackable"

# ActiveSupervisor Client - Send monitoring data to cloud or self-hosted instance
# Works seamlessly with SolidAgent for automatic agent monitoring
module ActiveSupervisorClient
  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
      
      # Initialize client after configuration
      @client = nil
      client
    end

    def client
      @client ||= Client.new(configuration)
    end

    # Main tracking methods
    def track(event_name, properties = {})
      client.track(event_name, properties)
    end

    def identify(user_id, traits = {})
      client.identify(user_id, traits)
    end

    def track_agent_interaction(agent_class, action, data = {})
      track("agent_interaction", {
        agent: agent_class.to_s,
        action: action.to_s,
        timestamp: Time.current.iso8601
      }.merge(data))
    end

    def track_generation(generation_data)
      track("generation", generation_data)
    end

    def track_prompt_cycle(cycle_data)
      track("prompt_generation_cycle", cycle_data)
    end

    def track_action_execution(action_data)
      track("action_execution", action_data)
    end

    # Batch operations
    def batch
      client.batch { yield }
    end

    def flush
      client.flush
    end

    # Health check
    def healthy?
      client.healthy?
    end
  end
end

# Auto-configure if Rails is present
if defined?(Rails)
  require "active_supervisor_client/railtie"
end