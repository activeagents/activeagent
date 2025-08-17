require "yaml"
require "abstract_controller"
require "active_agent/configuration"
require "active_agent/generation_provider"
require "active_agent/version"
require "active_agent/deprecator"
require "active_agent/railtie" if defined?(Rails)
require "active_agent/sanitizers"

require "active_support"
require "active_support/rails"
require "active_support/core_ext/class"
require "active_support/core_ext/module/attr_internal"
require "active_support/core_ext/string/inflections"
require "active_support/lazy_load_hooks"
module ActiveAgent
  include ActiveAgent::Sanitizers
  extend ActiveSupport::Autoload

  eager_autoload do
    autoload :Collector
  end

  autoload :Base
  autoload :Callbacks
  autoload :InlinePreviewInterceptor
  autoload :PromptHelper
  autoload :Generation
  autoload :GenerationProvider
  autoload :QueuedGeneration
  autoload :Parameterized
  autoload :Preview
  autoload :Previews, "active_agent/preview"
  autoload :GenerationJob

  class << self
    attr_accessor :config

    def eager_load!
      super

      Base.descendants.each do |agent|
        agent.eager_load! unless agent.abstract?
      end
    end

    # @return [void]
    def configure
      yield self

      sanitizers_reset!
    end

    # @return [void]
    def load_configuration(file)
      if File.exist?(file)
        config_file = YAML.load(ERB.new(File.read(file)).result, aliases: true)
        env = ENV["RAILS_ENV"] || ENV["ENV"] || "development"
        @config = config_file[env] || config_file
      else
        @config = {}
      end

      sanitizers_reset!
    end
  end
end

autoload :Mime, "action_dispatch/http/mime_type"

ActiveSupport.on_load(:action_view) do
  ActionView::Base.default_formats ||= Mime::SET.symbols
  ActionView::Template.mime_types_implementation = Mime
  ActionView::LookupContext::DetailsKey.clear
end
