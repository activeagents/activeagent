require "capybara"
require "capybara/cuprite"

class BrowserAgent < ApplicationAgent
  # Configure AI provider for intelligent automation
  generate_with :openai,
    model: "gpt-4o-mini"

  class_attribute :browser_session, default: nil

  # Navigate to a URL
  def navigate
    setup_browser_if_needed

    @url = params[:url]
    Rails.logger.info "Navigating to #{@url}"

    begin
      self.class.browser_session.visit(@url)
      @status = 200
      @current_url = self.class.browser_session.current_url
      @title = self.class.browser_session.title
    rescue => e
      @status = 500
      @error = e.message
      Rails.logger.error "Navigation failed: #{e.message}"
    end

    prompt
  end

  # Click on an element
  def click
    setup_browser_if_needed

    @selector = params[:selector]
    @text = params[:text]
    Rails.logger.info "Clicking on element: selector=#{@selector}, text=#{@text}"

    begin
      if @text
        self.class.browser_session.click_on(@text)
      elsif @selector
        self.class.browser_session.find(@selector).click
      end
      @success = true
      @current_url = self.class.browser_session.current_url
    rescue => e
      @success = false
      @error = e.message
      Rails.logger.error "Click failed: #{e.message}"
    end

    prompt
  end

  # Fill in a form field
  def fill_form
    setup_browser_if_needed

    @field = params[:field]
    @value = params[:value]
    @selector = params[:selector]
    Rails.logger.info "Filling form field: field=#{@field}, selector=#{@selector}"

    begin
      if @selector
        self.class.browser_session.find(@selector).set(@value)
      else
        self.class.browser_session.fill_in(@field, with: @value)
      end
      @success = true
    rescue => e
      @success = false
      @error = e.message
      Rails.logger.error "Fill form failed: #{e.message}"
    end

    prompt
  end

  # Extract text from the page
  def extract_text
    setup_browser_if_needed

    @selector = params[:selector] || "body"
    Rails.logger.info "Extracting text from #{@selector}"

    begin
      element = self.class.browser_session.find(@selector)
      @text = element.text
      @success = true
    rescue => e
      @success = false
      @error = e.message
      Rails.logger.error "Extract text failed: #{e.message}"
    end

    prompt
  end

  # Get current page info
  def page_info
    setup_browser_if_needed

    Rails.logger.info "Getting page info"

    begin
      @current_url = self.class.browser_session.current_url
      @title = self.class.browser_session.title
      @has_css = {}

      # Check for common elements
      [ "form", "input", "button", "a", "img" ].each do |tag|
        @has_css[tag] = self.class.browser_session.has_css?(tag)
      end

      @success = true
    rescue => e
      @success = false
      @error = e.message
      Rails.logger.error "Page info failed: #{e.message}"
    end

    prompt
  end

  # Extract all links from the page
  def extract_links
    setup_browser_if_needed

    @selector = params[:selector] || "body"
    @limit = params[:limit] || 10
    Rails.logger.info "Extracting links from #{@selector}"

    begin
      @links = []
      within_element = (@selector == "body") ? self.class.browser_session : self.class.browser_session.find(@selector)

      within_element.all("a", visible: true).first(@limit).each do |link|
        href = link["href"]
        next if href.nil? || href.empty? || href.start_with?("#")

        @links << {
          text: link.text.strip,
          href: href,
          title: link["title"]
        }
      end

      @success = true
      @current_url = self.class.browser_session.current_url
    rescue => e
      @success = false
      @error = e.message
      @links = []
      Rails.logger.error "Extract links failed: #{e.message}"
    end

    prompt
  end

  # Follow a link by text or href
  def follow_link
    setup_browser_if_needed

    @text = params[:text]
    @href = params[:href]
    Rails.logger.info "Following link: text=#{@text}, href=#{@href}"

    begin
      if @text
        self.class.browser_session.click_link(@text)
      elsif @href
        link = self.class.browser_session.find("a[href*='#{@href}']")
        link.click
      else
        raise "Must provide either text or href parameter"
      end

      # Wait for navigation
      sleep 0.5

      @success = true
      @current_url = self.class.browser_session.current_url
      @title = self.class.browser_session.title
    rescue => e
      @success = false
      @error = e.message
      Rails.logger.error "Follow link failed: #{e.message}"
    end

    prompt
  end

  # Go back to previous page
  def go_back
    setup_browser_if_needed

    Rails.logger.info "Going back to previous page"

    begin
      self.class.browser_session.go_back
      sleep 0.5

      @success = true
      @current_url = self.class.browser_session.current_url
      @title = self.class.browser_session.title
    rescue => e
      @success = false
      @error = e.message
      Rails.logger.error "Go back failed: #{e.message}"
    end

    prompt
  end

  # Extract main content (useful for Wikipedia and articles)
  def extract_main_content
    setup_browser_if_needed

    Rails.logger.info "Extracting main content"

    begin
      # Try common content selectors
      content_selectors = [
        "#mw-content-text", # Wikipedia
        "main",
        "article",
        "[role='main']",
        ".content",
        "#content"
      ]

      @content = nil
      content_selectors.each do |selector|
        if self.class.browser_session.has_css?(selector)
          element = self.class.browser_session.find(selector)
          @content = element.text
          @selector_used = selector
          break
        end
      end

      @content ||= self.class.browser_session.find("body").text
      @current_url = self.class.browser_session.current_url
      @title = self.class.browser_session.title
      @success = true
    rescue => e
      @success = false
      @error = e.message
      Rails.logger.error "Extract main content failed: #{e.message}"
    end

    prompt
  end

  # Take a screenshot of the current page
  def screenshot
    setup_browser_if_needed

    @filename = params[:filename] || "screenshot_#{Time.now.to_i}.png"
    @full_page = params[:full_page] || false
    @selector = params[:selector]
    @area = params[:area] # { x: 0, y: 0, width: 400, height: 300 }
    @main_content_only = params[:main_content_only] != false # Default to true

    # Ensure tmp/screenshots directory exists
    screenshot_dir = Rails.root.join("tmp", "screenshots")
    FileUtils.mkdir_p(screenshot_dir)

    @path = screenshot_dir.join(@filename)
    Rails.logger.info "Taking screenshot: #{@filename}"

    begin
      # Build screenshot options
      options = { path: @path }

      # If main_content_only is true and no specific selector/area provided, try to detect main content
      if @main_content_only && !@selector && !@area
        main_area = detect_main_content_area
        if main_area
          options[:area] = main_area
          Rails.logger.info "Auto-cropping to main content area: #{main_area.inspect}"
        end
      else
        # Add full page option
        options[:full] = true if @full_page

        # Add selector option (for element screenshots)
        options[:selector] = @selector if @selector.present?

        # Add area option (for specific region screenshots)
        if @area.present?
          # Ensure area has the required keys and convert to symbol keys
          area_hash = {}
          area_hash[:x] = @area["x"] || @area[:x] if @area["x"] || @area[:x]
          area_hash[:y] = @area["y"] || @area[:y] if @area["y"] || @area[:y]
          area_hash[:width] = @area["width"] || @area[:width] if @area["width"] || @area[:width]
          area_hash[:height] = @area["height"] || @area[:height] if @area["height"] || @area[:height]

          options[:area] = area_hash if area_hash.any?
        end
      end

      # Take the screenshot with options
      self.class.browser_session.save_screenshot(**options)

      @success = true
      @filepath = @path.to_s
      @current_url = self.class.browser_session.current_url
      @title = self.class.browser_session.title

      # Generate a relative path for display
      @relative_path = @path.relative_path_from(Rails.root).to_s
    rescue => e
      @success = false
      @error = e.message
      Rails.logger.error "Screenshot failed: #{e.message}"
    end

    prompt
  end

  # Extract links with preview screenshots
  def extract_links_with_previews
    setup_browser_if_needed

    @selector = params[:selector] || "body"
    @limit = params[:limit] || 5
    Rails.logger.info "Extracting links with previews from #{@selector}"

    begin
      @links = []
      @original_url = self.class.browser_session.current_url
      within_element = (@selector == "body") ? self.class.browser_session : self.class.browser_session.find(@selector)

      # Get unique links
      all_links = within_element.all("a", visible: true)
      unique_links = {}

      all_links.each do |link|
        href = link["href"]
        next if href.nil? || href.empty? || href.start_with?("#") || href.start_with?("javascript:")

        # Normalize URL
        full_url = URI.join(@original_url, href).to_s rescue next
        next if unique_links.key?(full_url)

        unique_links[full_url] = {
          text: link.text.strip,
          href: full_url,
          title: link["title"]
        }

        break if unique_links.size >= @limit
      end

      # Take screenshots of each link
      unique_links.each_with_index do |(url, link_data), index|
        begin
          # Visit the link
          self.class.browser_session.visit(url)
          sleep 0.5 # Wait for page to load

          # Take a screenshot
          screenshot_filename = "preview_#{index}_#{Time.now.to_i}.png"
          screenshot_path = Rails.root.join("tmp", "screenshots", screenshot_filename)
          FileUtils.mkdir_p(File.dirname(screenshot_path))
          self.class.browser_session.save_screenshot(screenshot_path)

          link_data[:screenshot] = screenshot_path.relative_path_from(Rails.root).to_s
          link_data[:page_title] = self.class.browser_session.title

          @links << link_data
        rescue => e
          Rails.logger.warn "Failed to preview #{url}: #{e.message}"
          @links << link_data # Add without screenshot
        end
      end

      # Return to original page
      self.class.browser_session.visit(@original_url)

      @success = true
      @current_url = @original_url
    rescue => e
      @success = false
      @error = e.message
      @links = []
      Rails.logger.error "Extract links with previews failed: #{e.message}"
    end

    prompt
  end

  private

  def setup_browser_if_needed
    return if self.class.browser_session

    # Configure Cuprite driver if not already configured
    unless Capybara.drivers[:cuprite_agent]
      Capybara.register_driver :cuprite_agent do |app|
        Capybara::Cuprite::Driver.new(
          app,
          window_size: [ 1920, 1080 ], # Standard HD resolution
          browser_options: {
            "no-sandbox": nil,
            "disable-gpu": nil,
            "disable-dev-shm-usage": nil
          },
          inspector: false,
          headless: true
        )
      end
    end

    # Create a shared session for this agent class
    self.class.browser_session = Capybara::Session.new(:cuprite_agent)
  end

  def detect_main_content_area
    # Try to detect main content area based on common selectors
    main_selectors = [
      "main",                    # HTML5 main element
      "[role='main']",          # ARIA role
      "#main-content",          # Common ID
      "#main",                  # Common ID
      "#content",               # Common ID
      ".main-content",          # Common class
      ".content",              # Common class
      "article",               # Article element
      "#mw-content-text",      # Wikipedia
      ".container",            # Bootstrap/common framework
      "#root > div > main",    # React apps
      "body > div:nth-child(2)" # Fallback to second div
    ]

    main_selectors.each do |selector|
      if self.class.browser_session.has_css?(selector, wait: 0)
        begin
          # Get element position and dimensions using JavaScript
          rect = self.class.browser_session.evaluate_script(<<-JS)
            (function() {
              var elem = document.querySelector('#{selector}');
              if (!elem) return null;
              var rect = elem.getBoundingClientRect();
              return {
                x: Math.round(rect.left + window.scrollX),
                y: Math.round(rect.top + window.scrollY),
                width: Math.round(rect.width),
                height: Math.round(rect.height)
              };
            })()
          JS

          if rect && rect["width"] > 0 && rect["height"] > 0
            # Start from the element's Y position or skip header if element is at top
            start_y = (rect["y"] < 100) ? 150 : rect["y"]

            # Always use full viewport width and height from start_y
            return {
              x: 0,
              y: start_y,
              width: 1920,
              height: 1080 - start_y  # Full height minus the offset
            }
          end
        rescue => e
          Rails.logger.warn "Failed to get dimensions for #{selector}: #{e.message}"
        end
      end
    end

    # Default fallback: skip typical header area but keep full height
    {
      x: 0,
      y: 150,  # Skip typical header height
      width: 1920,
      height: 930  # 1080 - 150 = 930 to stay within viewport
    }
  end
end
