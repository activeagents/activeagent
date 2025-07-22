require_relative "response"

module ActiveAgent
  module GenerationProvider
    class TestProvider
      # Provides a store of all the generations sent with the TestProvider so you can check them.
      def self.generations
        @@generations ||= []
      end

      # Allows you to over write the default generations store from an array to some
      # other object.  If you just want to clear the store,
      # call TestProvider.generations.clear.
      #
      # If you place another object here, please make sure it responds to:
      #
      # * << (message)
      # * clear
      # * length
      # * size
      # * and other common Array methods
      def self.generations=(val)
        @@generations = val
      end

      def self.generate(context)
        "TestProvider is not a real generation provider, it is only used for testing purposes."
      end
      
      attr_accessor :options, :response

      def initialize(options = {})
        @options = options.dup
        @response = nil
      end

      def generate(context)
        assistant_message = ActiveAgent::ActionPrompt::Message.new(
          content: "Test response content",
          role: :assistant
        )
        
        # Add the assistant message to the existing context
        context.messages << assistant_message
        
        @response = ActiveAgent::GenerationProvider::Response.new(
          prompt: context,
          message: assistant_message,
          raw_response: "Test response content"
        )
        ActiveAgent::GenerationProvider::TestProvider.generations << context
        @response
      end

      def embed(context)
        @response = ActiveAgent::GenerationProvider::Response.new(
          prompt: context,
          message: ActiveAgent::ActionPrompt::Message.new(
            content: "Test embedding response",
            role: :assistant
          ),
          raw_response: [0.1, 0.2, 0.3] # Mock embedding vector
        )
        @response
      end

      def generate!(prompt)
        ActiveAgent::ActionPrompt::Prompt.new(prompt)
        ActiveAgent::GenerationProvider::TestProvider.generations << prompt
      end
    end
  end
end
