require_relative "message"

module ActiveAgent
  module ActionPrompt
    class Resolver
      attr_internal :args

      def initialize(args = {})
        binding.pry
        self.args = args
      end
    end
  end
end
