# frozen_string_literal: true

# ActiveJob is required lazily via Railtie to avoid loading it when not needed

module ActiveAgent
  # = Active Agent \GenerationJob
  #
  # The +ActiveAgent::GenerationJob+ class is used when you
  # want to generate content outside of the request-response cycle. It supports
  # sending messages with parameters.
  #
  # Exceptions are rescued and handled by the agent class.
  class GenerationJob < ActiveJob::Base # :nodoc:
    def self.require_active_job!
      unless defined?(ActiveJob)
        raise LoadError, "ActiveJob is required for ActiveAgent::GenerationJob. Please add 'gem \"active_job\"' to your Gemfile."
      end
    end

    queue_as do
      agent_class = arguments.first.constantize
      agent_class.generate_later_queue_name
    end

    rescue_from StandardError, with: :handle_exception_with_agent_class

    def perform(agent, agent_method, generation_method, args:, kwargs: nil, params: nil)
      agent_class = params ? agent.constantize.with(params) : agent.constantize
      prompt = if kwargs
        agent_class.public_send(agent_method, *args, **kwargs)
      else
        agent_class.public_send(agent_method, *args)
      end
      prompt.send(generation_method)
    end

    private

    # "Deserialize" the agent class name by hand in case another argument
    # (like a Global ID reference) raised DeserializationError.
    def agent_class
      if agent = Array(@serialized_arguments).first || Array(arguments).first
        agent.constantize
      end
    end

    def handle_exception_with_agent_class(exception)
      if klass = agent_class
        klass.handle_exception exception
      else
        raise exception
      end
    end
  end
end
