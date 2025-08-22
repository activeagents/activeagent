class ScrapingAgent < ApplicationAgent
  # `visit.json.erb`
  # `visit.text.erb`
  def visit
    Rails.logger.info "Stubbing always successful navigation to #{params[:url]}"
    @status = 200
    prompt
  end

  # `read_current_page.json.erb`
  # `read_current_page.text.erb`
  def read_current_page
    Rails.logger.info "Stubbing a read of Google homepage under maintenance (regardless of URL, for testing)"
    @title = "Google"
    @body = "Welcome to Google! Google is under maintenance until 13:15 UTC."
    prompt
  end
end
