# lib/active_agent/generation.rb
require "ostruct"

module ActiveAgent
  # Represents a deferred agent action ready for synchronous or asynchronous execution.
  #
  # Generation objects are returned when calling agent actions and provide methods
  # to execute the generation immediately or queue it for background processing.
  # They also provide convenient access to the underlying prompt properties.
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
    attr_internal :agent_class, :processed_agent,
                  :action_name, :args, :kwargs

    # @param agent_class [Class]
    # @param action_name [Symbol]
    # @param args [Array]
    # @param kwargs [Hash]
    def initialize(agent_class, action_name, *args, **kwargs)
      self.agent_class, self.action_name, self.args, self.kwargs = agent_class, action_name, args, kwargs
    end

    # @return [Boolean] whether the agent instance has been created and processed
    def processed?
      !!processed_agent
    end

    # Accesses the prompt options by processing the agent if needed.
    #
    # Allows inspecting prompt properties like messages, actions, and options
    # before executing generation. The agent is lazily processed on first access.
    #
    # @return [Hash] prompt options including :messages, :actions, and configuration
    def prompt_options
      ensure_agent_processed
      processed_agent.prompt_options
    end

    # Returns the last message in the prompt as an object with a content accessor.
    #
    # Wraps various message formats (String, Hash, objects) to provide consistent
    # `.content` access regardless of the underlying format.
    #
    # @return [OpenStruct, Object] message with `.content` method
    def message
      last_message = messages.last
      if last_message.is_a?(String)
        OpenStruct.new(content: last_message)
      elsif last_message.respond_to?(:content)
        last_message
      elsif last_message.is_a?(Hash)
        OpenStruct.new(content: last_message[:content] || last_message["content"])
      else
        OpenStruct.new(content: last_message.to_s)
      end
    end

    # @return [Array] messages in the prompt context
    def messages
      prompt_options[:messages] || []
    end

    # @return [Array] available actions (tools) for the agent
    def actions
      prompt_options[:actions] || []
    end

    # @return [Hash] prompt configuration options excluding messages and actions
    def options
      prompt_options.except(:messages, :actions)
    end

    # Queues the generation for background execution with immediate processing.
    #
    # Uses the agent's configured job class to enqueue. Raises error if agent
    # has already been accessed to prevent silent data loss.
    #
    # @param options [Hash] job options (queue, priority, wait, etc.)
    # @return [Object] the enqueued job instance
    # @raise [RuntimeError] if agent was accessed before queueing
    def generate_later!(options = {})
      enqueue_generation :generate_now!, options
    end

    # Queues the generation for background execution.
    #
    # Uses the agent's configured job class to enqueue. Raises error if agent
    # has already been accessed to prevent silent data loss.
    #
    # @param options [Hash] job options (queue, priority, wait, etc.)
    # @return [Object] the enqueued job instance
    # @raise [RuntimeError] if agent was accessed before queueing
    def generate_later(options = {})
      enqueue_generation :generate_now, options
    end

    # Executes prompt generation synchronously with immediate processing.
    #
    # Processes the agent action, runs generation callbacks, and executes the
    # prompt through the configured provider. Exceptions are handled through
    # the agent's rescue mechanism.
    #
    # @return [ActiveAgent::Providers::Response] the provider's response
    def generate_now!
      ensure_agent_processed
      processed_agent.handle_exceptions do
        processed_agent.run_callbacks(:generation) do
          processed_agent.process_prompt!
        end
      end
    end

    # Executes prompt generation synchronously.
    #
    # Processes the agent action, runs generation callbacks, and executes the
    # prompt through the configured provider. Exceptions are handled through
    # the agent's rescue mechanism.
    #
    # @return [ActiveAgent::Providers::Response] the provider's response
    def generate_now
      ensure_agent_processed
      processed_agent.handle_exceptions do
        processed_agent.run_callbacks(:generation) do
          processed_agent.process_prompt
        end
      end
    end

    # Executes embedding generation synchronously.
    #
    # Processes the agent action, runs embedding callbacks, and generates
    # embeddings through the configured provider. Exceptions are handled
    # through the agent's rescue mechanism.
    #
    # @return [ActiveAgent::Providers::Response] embedding response with vector data
    def embed_now
      ensure_agent_processed
      processed_agent.handle_exceptions do
        processed_agent.run_callbacks(:embedding) do
          processed_agent.process_embed
        end
      end
    end

    # Queues the embedding generation for background execution.
    #
    # @param options [Hash] job options (queue, priority, wait, etc.)
    # @return [Object] the enqueued job instance
    # @raise [RuntimeError] if agent was accessed before queueing
    def embed_later(options = {})
      enqueue_generation :embed_now, options
    end

    private

    # Creates and processes the agent instance.
    #
    # Lazily instantiates the agent and calls the action method to prepare
    # the prompt context. Cached after first call.
    #
    # @return [ActiveAgent::Base] the processed agent instance
    # @api private
    def ensure_agent_processed
      self.processed_agent ||= agent_class.new.tap do |agent|
        agent.process(action_name, *args, **kwargs)
      end
    end

    # Enqueues the generation for background processing.
    #
    # Prevents enqueuing if the agent has been accessed, as local changes
    # would be lost. Only method arguments are passed to the job, not the
    # agent instance state.
    #
    # @param generation_method [Symbol, String] method to call on the job
    # @param options [Hash] job configuration
    # @return [Object] the enqueued job
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
  end
end
