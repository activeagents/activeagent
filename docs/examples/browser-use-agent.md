---
title: Browser Use Agent
description: Browser automation with AI-driven control. Navigate web pages, interact with elements, extract content, and take screenshots using Cuprite/Chrome.
---
# {{ $frontmatter.title }}

Active Agent provides browser automation capabilities through the Browser Use Agent (similar to Anthropic's Computer Use), which can navigate web pages, interact with elements, extract content, and take screenshots using Cuprite/Chrome.

## Overview

The Browser Use Agent demonstrates how ActiveAgent can integrate with external tools like headless browsers to create powerful automation workflows. Following the naming convention of tools like Anthropic's Computer Use, it provides AI-driven browser control using familiar Rails patterns.

## Features

- **Navigate to URLs** - Direct browser navigation to any website
- **Click elements** - Click buttons, links, or any element using CSS selectors or text
- **Extract content** - Extract text from specific elements or entire pages
- **Take screenshots** - Capture full page or specific areas with HD resolution (1920x1080)
- **Fill forms** - Interact with form fields programmatically
- **Extract links** - Gather links from pages with optional preview screenshots
- **Smart content detection** - Automatically detect and focus on main content areas

## Setup

Generate a browser use agent:

```bash
rails generate active_agent:agent browser_use navigate click extract_text screenshot
```

## Agent Implementation

::: code-group

```ruby [browser_agent.rb]
require "capybara"
require "capybara/cuprite"

class BrowserAgent < ApplicationAgent
  # Configure AI provider for intelligent automation
  generate_with :openai, model: "gpt-4o-mini"

  class_attribute :browser_session, default: nil

  # Navigate to a URL
  def navigate
    setup_browser_if_needed
    @url = params[:url]

    begin
      self.class.browser_session.visit(@url)
      @status = 200
      @current_url = self.class.browser_session.current_url
      @title = self.class.browser_session.title
    rescue => e
      @status = 500
      @error = e.message
    end

    prompt
  end

  # Click on an element
  def click
    setup_browser_if_needed
    @selector = params[:selector]
    @text = params[:text]

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
    end

    prompt
  end

  # Extract text from the page
  def extract_text
    setup_browser_if_needed
    @selector = params[:selector] || "body"

    begin
      element = self.class.browser_session.find(@selector)
      @text = element.text
      @success = true
    rescue => e
      @success = false
      @error = e.message
    end

    prompt
  end

  # Take a screenshot of the current page
  def screenshot
    setup_browser_if_needed
    @filename = params[:filename] || "screenshot_#{Time.now.to_i}.png"
    @main_content_only = params[:main_content_only] != false # Default to true

    screenshot_dir = Rails.root.join("tmp", "screenshots")
    FileUtils.mkdir_p(screenshot_dir)
    @path = screenshot_dir.join(@filename)

    begin
      options = { path: @path }

      # Auto-detect and crop to main content if enabled
      if @main_content_only && !params[:selector] && !params[:area]
        main_area = detect_main_content_area
        options[:area] = main_area if main_area
      end

      self.class.browser_session.save_screenshot(**options)
      @success = true
      @filepath = @path.to_s
    rescue => e
      @success = false
      @error = e.message
    end

    prompt
  end

  # Extract main content from the page
  def extract_main_content
    setup_browser_if_needed

    begin
      content_selectors = [
        "#mw-content-text", # Wikipedia
        "main", "article", "[role='main']",
        ".content", "#content"
      ]

      @content = nil
      content_selectors.each do |selector|
        if self.class.browser_session.has_css?(selector)
          @content = self.class.browser_session.find(selector).text
          @selector_used = selector
          break
        end
      end

      @content ||= self.class.browser_session.find("body").text
      @success = true
    rescue => e
      @success = false
      @error = e.message
    end

    prompt
  end

  private

  def setup_browser_if_needed
    return if self.class.browser_session

    unless Capybara.drivers[:cuprite_agent]
      Capybara.register_driver :cuprite_agent do |app|
        Capybara::Cuprite::Driver.new(
          app,
          window_size: [1920, 1080],
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

    self.class.browser_session = Capybara::Session.new(:cuprite_agent)
  end

  def detect_main_content_area
    main_selectors = [
      "main", "[role='main']", "#main-content",
      "#content", "article", "#mw-content-text"
    ]

    main_selectors.each do |selector|
      if self.class.browser_session.has_css?(selector, wait: 0)
        begin
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
            start_y = (rect["y"] < 100) ? 150 : rect["y"]
            return { x: 0, y: start_y, width: 1920, height: 1080 - start_y }
          end
        rescue => e
          # Continue to next selector
        end
      end
    end

    # Default: skip header area
    { x: 0, y: 150, width: 1920, height: 930 }
  end
end
```

```erb [instructions.text.erb]
You are a browser automation agent that can navigate web pages and interact with web elements using Cuprite/Chrome.

You have access to the following browser actions:
<% controller.action_schemas.each do |schema| %>
- <%= schema["name"] %>: <%= schema["description"] %>
<% end %>

<% if params[:url].present? %>
Starting URL: <%= params[:url] %>
You should navigate to this URL first to begin your research.
<% end %>

Use these tools to help users automate web browsing tasks, extract information from websites, and perform user interactions.

When researching a topic:
1. Navigate to the provided URL or search for relevant pages
2. Extract the main content to understand the topic
3. Use the click action with specific text to navigate to related pages
4. Use go_back to return to previous pages when needed
5. Provide a comprehensive summary with reference URLs

Screenshot tips (browser is 1920x1080 HD resolution):
- Default screenshots automatically try to crop to main content
- For Wikipedia: { "x": 0, "y": 200, "width": 1920, "height": 880 }
- For specific elements, use the selector parameter
```

```ruby [screenshot.json.jbuilder]
json.name action_name
json.description "Take a screenshot of the current page"
json.parameters do
  json.type "object"
  json.properties do
    json.filename do
      json.type "string"
      json.description "Name for the screenshot file"
    end
    json.full_page do
      json.type "boolean"
      json.description "Whether to capture the full page"
    end
    json.main_content_only do
      json.type "boolean"
      json.description "Auto-detect and crop to main content (default: true)"
    end
    json.selector do
      json.type "string"
      json.description "CSS selector for specific element"
    end
    json.area do
      json.type "object"
      json.description "Specific area to capture"
      json.properties do
        json.x { json.type "integer" }
        json.y { json.type "integer" }
        json.width { json.type "integer" }
        json.height { json.type "integer" }
      end
    end
  end
end
```

:::

## Basic Navigation Example

The browser use agent can navigate to URLs and interact with pages using AI:

```ruby
response = BrowserAgent.prompt(
  message: "Navigate to https://www.example.com and tell me what you see"
).generate_now

assert response.message.content.present?
```

::: details Navigation Response Example
<!-- @include: @/parts/examples/browser-agent-test.rb-test-browser-agent-navigates-to-a-url-using-prompt-context.md -->
:::

## AI-Driven Browser Control

The browser use agent can use AI to determine which actions to take:

```ruby
response = BrowserAgent.prompt(
  message: "Go to https://www.example.com and extract the main heading"
).generate_now

# Check that AI used the tools
assert response.prompt.messages.any? { |m| m.role == :tool }
assert response.message.content.present?
```

::: details AI Browser Response Example
<!-- @include: @/parts/examples/browser-agent-test.rb-test-browser-agent-uses-actions-as-tools-with-ai.md -->
:::

## Direct Action Usage

You can also call browser actions directly without AI:

```ruby
# Call navigate action directly (synchronous execution)
navigate_response = BrowserAgent.with(
  url: "https://www.example.com"
).navigate

# The action returns a Generation object
assert_kind_of ActiveAgent::Generation, navigate_response

# Execute the generation
result = navigate_response.generate_now

assert result.message.content.include?("navigated")
```

::: details Direct Action Response Example
<!-- @include: @/parts/examples/browser-agent-test.rb-test-browser-agent-can-be-used-directly-without-ai.md -->
:::

## Wikipedia Research Example

The browser use agent excels at research tasks, navigating between pages and gathering information:

```ruby
response = BrowserAgent.prompt(
  message: "Research the Apollo 11 moon landing mission. Start at the main Wikipedia article, then:
            1) Extract the main content to get an overview
            2) Find and follow links to learn about the crew members
            3) Take screenshots of important pages
            4) Extract key dates and mission objectives
            Please provide a comprehensive summary.",
  url: "https://en.wikipedia.org/wiki/Apollo_11"
).generate_now

# The agent should navigate to Wikipedia and gather information
assert response.message.content.present?
assert response.message.content.downcase.include?("apollo") ||
  response.message.content.downcase.include?("moon")

# Check that multiple tools were used
tool_messages = response.prompt.messages.select { |m| m.role == :tool }
assert tool_messages.any?, "Should have used tools"
```

::: details Wikipedia Research Response Example
<!-- @include: @/parts/examples/browser-agent-test.rb-test-browser-agent-researches-a-topic-on-wikipedia.md -->
:::

## Area Screenshot Example

Take screenshots of specific page regions:

```ruby
response = BrowserAgent.prompt(
  message: "Navigate to https://www.example.com and take a screenshot of just the header area (top 200 pixels)"
).generate_now

assert response.message.content.present?

# Check that screenshot tool was used
tool_messages = response.prompt.messages.select { |m| m.role == :tool }
assert tool_messages.any? { |m| m.content.include?("screenshot") }
```

::: details Area Screenshot Response Example
<!-- @include: @/parts/examples/browser-agent-test.rb-test-browser-agent-takes-area-screenshot.md -->
:::

## Main Content Auto-Cropping

The browser use agent can automatically detect and crop to main content areas:

```ruby
response = BrowserAgent.prompt(
  message: "Navigate to Wikipedia's Apollo 11 page and take a screenshot of the main content (should automatically exclude navigation/header)"
).generate_now

assert response.message.content.present?

# Check that screenshot was taken
tool_messages = response.prompt.messages.select { |m| m.role == :tool }
assert tool_messages.any? { |m| m.content.include?("screenshot") }
```

::: details Main Content Crop Response Example
<!-- @include: @/parts/examples/browser-agent-test.rb-test-browser-agent-auto-crops-main-content.md -->
:::

## Screenshot Capabilities

The screenshot action provides multiple options for capturing page content:

### Full Page Screenshot
```ruby
BrowserAgent.with(
  url: "https://example.com"
).navigate.generate_now

BrowserAgent.new.screenshot(
  filename: "full_page.png",
  full_page: true
)
```

### Area Screenshot
```ruby
BrowserAgent.new.screenshot(
  filename: "header.png",
  area: { x: 0, y: 0, width: 1920, height: 200 }
)
```

### Element Screenshot
```ruby
BrowserAgent.new.screenshot(
  filename: "content.png",
  selector: "#main-content"
)
```

### Auto-Crop to Main Content
```ruby
BrowserAgent.new.screenshot(
  filename: "main.png",
  main_content_only: true  # Default behavior
)
```

## Browser Configuration

The browser runs in HD resolution (1920x1080) with headless Chrome:

```ruby
def setup_browser_if_needed
  Capybara.register_driver :cuprite_agent do |app|
    Capybara::Cuprite::Driver.new(
      app,
      window_size: [1920, 1080], # HD resolution
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
```

## Smart Content Detection

The browser use agent includes intelligent content detection that:
- Identifies main content areas using common selectors
- Skips headers and navigation automatically
- Adjusts cropping based on page structure
- Falls back to sensible defaults

Common selectors checked:
- `main`, `[role='main']`
- `#main-content`, `#content`
- `article`
- `#mw-content-text` (Wikipedia)
- `.container` (Bootstrap)

## Tips for Effective Use

### Navigation Best Practices
- Use `click` with text parameter for specific links
- Extract main content before navigating away
- Use `go_back` to return to previous pages
- Take screenshots of important pages

### Wikipedia Research
- Use selector `#mw-content-text` for article content
- Click directly on relevant links rather than extracting all links
- Take screenshots with `main_content_only: true` to exclude navigation

### Screenshot Optimization
- Default `main_content_only: true` crops out headers automatically
- Use area parameter for specific regions: `{ x: 0, y: 150, width: 1920, height: 930 }`
- For Wikipedia, consider `y: 200` to skip navigation bars
- Full page screenshots available with `full_page: true`

## Integration with Rails

The Browser Use Agent integrates seamlessly with Rails applications:

```ruby
class WebScraperController < ApplicationController
  def scrape
    response = BrowserAgent.prompt(
      message: params[:instructions],
      url: params[:url]
    ).generate_now

    render json: {
      content: response.message.content,
      screenshots: response.prompt.messages
        .select { |m| m.role == :tool && m.content.include?("screenshot") }
        .map { |m| m.content.match(/File: (.+?)\\n/)[1] }
    }
  end
end
```

## Advanced Usage

### Multi-Page Navigation Flow
```ruby
agent = BrowserAgent.new

# Navigate to main page
agent.navigate(url: "https://example.com")

# Extract main content
content = agent.extract_main_content

# Click specific link
agent.click(text: "Learn More")

# Take screenshot of new page
agent.screenshot(main_content_only: true)

# Go back
agent.go_back

# Extract links for further exploration
links = agent.extract_links(selector: "#main-content")
```

### Form Interaction
```ruby
agent = BrowserAgent.new
agent.navigate(url: "https://example.com/form")
agent.fill_form(field: "email", value: "test@example.com")
agent.fill_form(field: "message", value: "Hello world")
agent.click(text: "Submit")
agent.screenshot(filename: "form_result.png")
```

## Requirements

- **Cuprite** gem for Chrome automation
- **Chrome** or **Chromium** browser installed
- **Capybara** for browser session management

Add to your Gemfile:
```ruby
gem 'cuprite'
gem 'capybara'
```

## Conclusion

The Browser Use Agent demonstrates ActiveAgent's flexibility in integrating with external tools while maintaining Rails conventions. Following the pattern of tools like Anthropic's Computer Use, it provides powerful browser automation capabilities driven by AI, making it ideal for:

- Web scraping and data extraction
- Automated testing and verification
- Research and information gathering
- Screenshot generation for documentation
- Form submission and interaction
