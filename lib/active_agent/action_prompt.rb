require "abstract_controller"
require "active_support/core_ext/string/inflections"

module ActiveAgent
  module ActionPrompt
    extend ::ActiveSupport::Autoload

    eager_autoload do
      autoload :Collector
      autoload :Message
      autoload :Prompt
      autoload :TestCase
      autoload :PromptHelper
    end

    autoload :Base

    extend ActiveSupport::Concern
  end
end
