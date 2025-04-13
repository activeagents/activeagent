require "abstract_controller"
require "active_support/core_ext/string/inflections"

module ActiveAgent
  module ActionPrompt
    extend ::ActiveSupport::Autoload

    eager_autoload do
      autoload :Collector
      autoload :Message
      autoload :Prompt
      autoload :PromptHelper
    end

    autoload :Base

    extend ActiveSupport::Concern

    included do
      include AbstractController::Rendering
      include AbstractController::Layouts
      include AbstractController::Helpers
      include AbstractController::Translation
      include AbstractController::AssetPaths
      include AbstractController::Callbacks
      include AbstractController::Caching

      include ActionView::Layouts

      helper ActiveAgent::PromptHelper
      # class_attribute :default_params, default: {
      #   content_type: "text/plain",
      #   parts_order: ["text/plain", "text/html", "application/json"]
      # }.freeze
    end

    class TestAgent
      class << self
        attr_accessor :generations
      end
    end
  end
end
