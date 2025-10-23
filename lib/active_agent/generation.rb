# frozen_string_literal: true

require "active_agent/providers/common/messages/_types"

module ActiveAgent
  # Deferred agent action ready for synchronous or asynchronous execution.
  #
  # Returned when calling agent actions. Provides methods to execute immediately
  # or queue for background processing, plus access to prompt properties before execution.
  #
  # @example Synchronous generation
  #   generation = MyAgent.with(message: "Hello").greet
  #   response = generation.generate_now
  #
  # @example Asynchronous generation
  #   MyAgent.with(message: "Hello").greet.generate_later(queue: :prompts)
  #
  # @example Accessing prompt properties before generation
  #   generation = MyAgent.prompt(message: "Hello")
  #   generation.message.content  # => "Hello"
  #   generation.messages         # => [...]
  class Generation
    attr_internal :agent_class, :action_name, :args, :kwargs

    # @param agent_class [Class]
    # @param action_name [Symbol]
    # @param args [Array]
    # @param kwargs [Hash]
    def initialize(agent_class, action_name, *args, **kwargs)
      self.agent_class, self.action_name, self.args, self.kwargs = agent_class, action_name, args, kwargs
    end

    # @return [Boolean]
    def processed?
      !!agent
    end

    # Accesses prompt options by processing the agent if needed.
    #
    # Lazily processes the agent on first access, allowing inspection of
    # prompt properties before executing generation.
    #
    # @return [Hash] with :messages, :actions, and configuration keys
    def prompt_options
      agent.prompt_options
    end

    # @return [Hash] configuration options excluding messages and actions
    def options
      prompt_options.except(:messages, :actions)
    end

    def instructions
      agent.prompt_view_instructions(prompt_options[:instructions])
    end

    # @return [Array]
    def messages
      prompt_options[:messages] || []
    end

    # Returns the last message with consistent `.content` access.
    #
    # Wraps various message formats (String, Hash, objects) using the common
    # MessageType for uniform access patterns.
    #
    # @return [ActiveAgent::Providers::Common::Messages::Base, nil]
    def message
      last_message = messages.last
      return nil unless last_message

      message_type.cast(last_message)
    end

    # @return [Array]
    def actions
      prompt_options[:actions] || []
    end

    # Queues for background execution with immediate processing.
    #
    # @param options [Hash] job options (queue, priority, wait, etc.)
    # @return [Object] enqueued job instance
    # @raise [RuntimeError] if agent was accessed before queueing
    def generate_later!(options = {})
      enqueue_generation :generate_now!, options
    end

    # Queues for background execution.
    #
    # @param options [Hash] job options (queue, priority, wait, etc.)
    # @return [Object] enqueued job instance
    # @raise [RuntimeError] if agent was accessed before queueing
    def generate_later(options = {})
      enqueue_generation :generate_now, options
    end

    # Executes prompt generation synchronously with immediate processing.
    #
    # @return [ActiveAgent::Providers::Response]
    def generate_now!
      agent.handle_exceptions do
        agent.run_callbacks(:generation) do
          agent.process_prompt!
        end
      end
    end

    # Executes prompt generation synchronously.
    #
    # @return [ActiveAgent::Providers::Response]
    def generate_now
      agent.handle_exceptions do
        agent.run_callbacks(:generation) do
          agent.process_prompt
        end
      end
    end

    # Executes embedding generation synchronously.
    #
    # @return [ActiveAgent::Providers::Response] embedding response with vector data
    def embed_now
      agent.handle_exceptions do
        agent.run_callbacks(:embedding) do
          agent.process_embed
        end
      end
    end

    # Queues embedding generation for background execution.
    #
    # @param options [Hash] job options (queue, priority, wait, etc.)
    # @return [Object] enqueued job instance
    # @raise [RuntimeError] if agent was accessed before queueing
    def embed_later(options = {})
      enqueue_generation :embed_now, options
    end

    private

    # Lazily instantiates and processes the agent instance.
    #
    # Cached after first call.
    #
    # @return [ActiveAgent::Base]
    # @api private
    def agent
      @agent ||= agent_class.new.tap do |agent|
        agent.params = @params
        agent.process(action_name, *args, **kwargs)
      end
    end

    # Enqueues for background processing.
    #
    # Prevents enqueuing if the agent has been accessed, as local changes
    # would be lost. Only method arguments are passed to the job, not the
    # agent instance state.
    #
    # @param generation_method [Symbol, String]
    # @param options [Hash]
    # @return [Object] enqueued job
    # @raise [RuntimeError] when agent already processed to prevent data loss
    # @api private
    def enqueue_generation(generation_method, options = {})
      if processed?
        ::Kernel.raise "You've accessed the agent before asking to " \
          "generate it later, so you may have made local changes that would " \
          "be silently lost if we enqueued a job to generate it. Why? Only " \
          "the agent method *arguments* are passed with the generation job! " \
          "Do not access the agent in any way if you mean to generate it " \
          "later. Workarounds: 1. don't touch the agent before calling " \
          "#generate_later, 2. only touch the agent *within your agent " \
          "method*, or 3. use a custom Active Job instead of #generate_later."
      else
        agent_class.generation_job.set(options).perform_later(
          agent_class.name, action_name.to_s, generation_method.to_s, args: args, kwargs: kwargs
        )
      end
    end

    # Lazy-loaded message type instance for casting messages.
    #
    # @return [ActiveAgent::Providers::Common::Messages::Types::MessageType]
    # @api private
    def message_type
      @message_type ||= ActiveAgent::Providers::Common::Messages::Types::MessageType.new
    end
  end
end
