module ActiveAgent
  module ActionPrompt
    class Base < AbstractController::Base
      class NullPrompt # :nodoc:
        def message
          ""
        end

        def header
          {}
        end

        def respond_to?(string, include_all = false)
          true
        end

        def method_missing(...)
          nil
        end
      end
    end
  end
end
