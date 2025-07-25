module ActiveAgent
  module GenerationProvider
    class BaseAdapter
      attr_reader :prompt

      def initialize(prompt)
        @prompt = prompt
      end

      def input
        raise NotImplementedError, "Subclasses must implement the 'input' method"
      end

      def response
        raise NotImplementedError, "Subclasses must implement the 'response' method"
      end
    end
  end
end
