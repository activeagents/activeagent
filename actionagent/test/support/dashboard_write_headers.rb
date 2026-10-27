# frozen_string_literal: true

# The headers the dashboard page sends with a write from the browser: the
# page's CSRF token when it renders one (frontend utils/apiFetch.mjs), and the
# Sec-Fetch-Site a browser adds to a request from the page's own origin.
# Rails through 8.1 verifies the token. Rails 8.2's :header_only strategy
# verifies the header and renders no token, so csrf_meta_tags is empty there.
module DashboardWriteHeaders
  def dashboard_write_headers
    get "/activeagents"
    token = Nokogiri::HTML(response.body).at_css('meta[name="csrf-token"]')&.[]("content")
    headers = { "Sec-Fetch-Site" => "same-origin" }
    token ? headers.merge("X-CSRF-Token" => token) : headers
  end
end
