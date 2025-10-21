# frozen_string_literal: true

require "active_agent/collector"

module ActiveAgent
  # Provides template lookup and rendering for agent classes.
  #
  # Enables rendering instructions from templates or direct strings,
  # loading JSON schemas from template files, and collecting responses
  # from templates, blocks, or text.
  module View
    extend ActiveSupport::Concern

    private

    ##### Instructions Templating ###########################################

    # Prepares instructions from various input formats.
    #
    # Accepts multiple formats:
    # - String: returned as-is
    # - Symbol: invokes method with that name (like ActiveRecord callbacks)
    # - Array: must contain only strings
    # - Hash: requires :template key, optional :locals
    # - nil: renders default "instructions" template
    #
    # @param param [Hash, String, Symbol, Array<String>, nil]
    # @return [String, Array<String>, nil] nil if template not found
    # @raise [ArgumentError] if format is invalid or Hash missing :template key
    def prompt_view_instructions(param)
      case param
      when String
        param.presence

      when Symbol
        send(param)

      when Array
        raise ArgumentError, "Instructions array must contain only strings" unless param.all?(String)
        param.presence

      when Hash
        raise ArgumentError, "Expected `:template` key in instructions hash" unless param[:template]
        view_render_template(param[:template], **param[:locals])

      when nil
        view_render_template("instructions")

      else
        raise ArgumentError, "Instructions must be Hash, String, Symbol or nil"
      end
    end

    ##### Action Templating #################################################

    # Renders template for a prompt action/message.
    #
    # @param action_name [String, Symbol]
    # @param locals [Hash]
    # @return [String, nil]
    def prompt_view_message(action_name, **locals)
      view_render_template(action_name, **locals)
    end

    # Renders template for embedding input.
    #
    # @param action_name [String, Symbol]
    # @param locals [Hash]
    # @return [String, nil]
    def embed_view_input(action_name, **locals)
      view_render_template(action_name, **locals)
    end

    ##### Shared Helpers ####################################################

    # Renders a template if it exists in any supported ERB format.
    #
    # @param template_name [String, Symbol]
    # @param locals [Hash] local variables to pass to template
    # @return [String, nil] nil if template not found
    def view_render_template(template_name, **locals)
      return unless lookup_context.exists?(template_name, agent_name, false)

      template = lookup_context.find_template(template_name, agent_name, false)

      render_to_string(template: template.virtual_path, locals:, layout: false).chomp.presence
    end
  end
end
