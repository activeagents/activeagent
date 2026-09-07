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

    # Performs a queued generation.
    #
    # Action generations (+Agent.with(...).action.generate_later+) call the
    # action on the agent class and then the generation method on the result.
    #
    # Direct generations (+Agent.prompt(...).generate_later+ and
    # +Agent.embed(...).embed_later+) have no action to call: the synthetic
    # +agent_method+ they enqueue is not a real method. When
    # +direct_generation_type+ is present the job rebuilds the
    # {ActiveAgent::Parameterized::DirectGeneration} from the enqueued
    # arguments and options instead, so the worker runs the same code path as
    # +generate_now+ / +embed_now+.
    def perform(agent, agent_method, generation_method, args:, kwargs: nil, params: nil,
                direct_generation_type: nil, direct_args: nil, direct_options: nil)
      generation = if direct_generation_type
        direct_generation(agent, direct_generation_type, params, direct_args, direct_options)
      else
        agent_class = params ? agent.constantize.with(params) : agent.constantize
        if kwargs
          agent_class.public_send(agent_method, *args, **kwargs)
        else
          agent_class.public_send(agent_method, *args)
        end
      end

      generation.send(generation_method)
    end

    private

    # Rebuilds a direct prompt/embed generation from its serialized parts.
    #
    # Active Job round-trips symbols and symbol-keyed hashes, but the keys are
    # normalized here anyway so a job enqueued by an older adapter (or a
    # hand-built one) still performs.
    def direct_generation(agent, generation_type, params, direct_args, direct_options)
      options = (direct_options || {}).to_h.symbolize_keys

      ActiveAgent::Parameterized::DirectGeneration.new(
        agent.constantize, generation_type.to_sym, params || {}, *(direct_args || []), **options
      )
    end

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
