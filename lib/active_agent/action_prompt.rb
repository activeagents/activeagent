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

    # # def self.prompt(headers = {}, &)
    # #   new.prompt(headers, &)
    # # end

    # def prompt(headers = {}, &block)
    #   return @_message if @_prompt_was_called && headers.blank? && !block

    #   headers = apply_defaults(headers)

    #   @_message = ActiveAgent::ActionPrompt::Prompt.new

    #   assign_headers_to_message(@_message, headers)

    #   responses = collect_responses(headers, &block)

    #   @_prompt_was_called = true

    #   create_parts_from_responses(@_message, responses)

    #   @_message
    # end

    private

    def apply_defaults(headers)
      headers.reverse_merge(self.class.default_params)
    end

    def assign_headers_to_message(message, headers)
      assignable = headers.except(:parts_order, :content_type, :body, :template_name, :template_path)
      assignable.each { |k, v| message.send(:"#{k}=", v) }
    end

    def collect_responses(headers, &block)
      if block
        collect_responses_from_block(headers, &block)
      elsif headers[:body]
        collect_responses_from_text(headers)
      else
        collect_responses_from_templates(headers)
      end
    end

    def collect_responses_from_block(headers, &block)
      templates_name = headers[:template_name] || action_name
      collector = ActiveAgent::ActionPrompt::Collector.new(lookup_context) { render(templates_name) }
      yield(collector)
      collector.responses
    end

    def collect_responses_from_text(headers)
      [{
        body: headers.delete(:body),
        content_type: headers[:content_type] || "text/plain"
      }]
    end

    def collect_responses_from_templates(headers)
      templates_path = headers[:template_path] || self.class.name.sub(/Agent$/, "").underscore
      templates_name = headers[:template_name] || action_name
      each_template(Array(templates_path), templates_name).map do |template|
        format = template.format || formats.first
        {
          body: render(template: template, formats: [format]),
          content_type: Mime[format].to_s
        }
      end
    end

    def each_template(paths, name, &)
      templates = lookup_context.find_all(name, paths)
      if templates.empty?
        raise ActionView::MissingTemplate.new(paths, name, paths, false, "prompt")
      else
        templates.uniq(&:format).each(&)
      end
    end

    def create_parts_from_responses(message, responses)
      responses.each do |response|
        message.add_part(response[:body], content_type: response[:content_type])
      end
    end

    class TestAgent
      class << self
        attr_accessor :generations
      end
    end
  end
end
