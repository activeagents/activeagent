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
      attr_accessor :options

      def initialize(options = {})
        @options = options.dup
      end

      def response
        ActiveAgent::GenerationProvider::Response.new(
          prompt: ActiveAgent::ActionPrompt::Prompt.new("Test response"),
          message: ActiveAgent::ActionPrompt::Message.new(
            content: "Test response content",
            role: :assistant
          ),
          raw_response: "Test response content"
        )
      end

      def generate!(prompt)
        ActiveAgent::ActionPrompt::Prompt.new(prompt)

        ActiveAgent::GenerationProvider::TestProvider.generations << prompt
      end
    end
  end
end
