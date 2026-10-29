# frozen_string_literal: true

require "rails/application_controller"

class Rails::AgentsController < Rails::ApplicationController # :nodoc:
  prepend_view_path File.expand_path("../active_agent/preview/templates", __dir__)
  layout "active_agent/preview"
  before_action :require_local!

  def index
    @previews = ActiveAgent::Preview.all
  end

  def preview
    if found = ActiveAgent::Preview.find(params[:path])
      @previews = [ found ]
      render :index
    elsif load_preview
      render :preview
    end
  end

  def download
    return unless load_preview

    send_data @content, type: "text/markdown", disposition: "attachment",
      filename: "#{@preview.preview_name.tr('/', '-')}-#{@prompt}.md"
  end

  private

  def load_preview
    name, _, @prompt = params[:path].to_s.rpartition("/")
    @preview = ActiveAgent::Preview.find(name)
    unless @preview&.prompt_exists?(@prompt)
      head :not_found
      return false
    end

    @content = @preview.call(@prompt, request.query_parameters).prompt_preview
    true
  end
end
