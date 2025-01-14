# frozen_string_literal: true

require "active_job"

module ActiveAgent
  # = Active Agent \GenerationJob
  #
  # The +ActiveAgent::GenerationJob+ class is used when you
  # want to generate content outside of the request-response cycle. It supports
  # sending messages with parameters.
  #
  # Exceptions are rescued and handled by the agent class.
  class GenerationJob < ActiveJob::Base # :nodoc:
    queue_as do
      agent_class = arguments.first.constantize
      agent_class.generate_later_queue_name
    end

    rescue_from StandardError, with: :handle_exception_with_agent_class

    def perform(agent_class_name, action_name, args:, params: nil)
      agent_class = agent_class_name.constantize
      agent = agent_class.new
      agent.params = params if params
      agent.process(action_name, *args)
      agent.generate
    end

    private

    # "Deserialize" the agent class name by hand in case another argument
    # (like a Global ID reference) raised DeserializationError.
    def agent_class
      if (agent = Array(@serialized_arguments).first || Array(arguments).first)
        agent.constantize
      end
    end

    def handle_exception_with_agent_class(exception)
      if (klass = agent_class)
        klass.handle_exception exception
      else
        raise exception
      end
    end
  end
end
