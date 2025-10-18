require "yaml"
require "abstract_controller"
require "active_agent/configuration"
require "active_agent/version"
require "active_agent/deprecator"
require "active_agent/railtie" if defined?(Rails)
require "active_agent/sanitizers"
require "active_agent/log_subscriber"

require "active_support"
require "active_support/rails"
require "active_support/core_ext/class"
require "active_support/core_ext/module/attr_internal"
require "active_support/core_ext/string/inflections"
require "active_support/lazy_load_hooks"

module ActiveAgent
  # include ActiveAgent::Sanitizers
  extend ActiveSupport::Autoload

  eager_autoload do
    autoload :Collector
  end

  autoload :Base
  autoload :Callbacks
  autoload :Streaming
  autoload :InlinePreviewInterceptor
  autoload :Generation
  autoload :QueuedGeneration
  autoload :Parameterized
  autoload :Preview
  autoload :Previews, "active_agent/preview"
  autoload :GenerationJob

  class << self
    def eager_load!
      super

      Base.descendants.each do |agent|
        agent.eager_load! unless agent.abstract?
      end
    end
  end
end

autoload :Mime, "action_dispatch/http/mime_type"

ActiveSupport.on_load(:action_view) do
  ActionView::Base.default_formats ||= Mime::SET.symbols
  ActionView::Template.mime_types_implementation = Mime
  ActionView::LookupContext::DetailsKey.clear
end
