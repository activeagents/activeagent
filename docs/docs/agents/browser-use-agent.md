---
title: Browser Use Agent
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

<<< @/../test/dummy/app/agents/browser_agent.rb {ruby}

<<< @/../test/dummy/app/views/browser_agent/instructions.text.erb {erb}

<<< @/../test/dummy/app/views/browser_agent/screenshot.json.jbuilder {ruby}

:::

## Basic Navigation Example

The browser use agent can navigate to URLs and interact with pages using AI:

<<< @/../test/agents/browser_agent_test.rb#navigate_example {ruby:line-numbers}

::: details Navigation Response Example
<!-- @include: @/parts/examples/browser-agent-test.rb-test-browser-agent-navigates-to-a-url-using-prompt-context.md -->
:::

## AI-Driven Browser Control

The browser use agent can use AI to determine which actions to take:

<<< @/../test/agents/browser_agent_test.rb#ai_browser_example {ruby:line-numbers}

::: details AI Browser Response Example
<!-- @include: @/parts/examples/browser-agent-test.rb-test-browser-agent-uses-actions-as-tools-with-ai.md -->
:::

## Direct Action Usage

You can also call browser actions directly without AI:

<<< @/../test/agents/browser_agent_test.rb#direct_action_example {ruby:line-numbers}

::: details Direct Action Response Example
<!-- @include: @/parts/examples/browser-agent-test.rb-test-browser-agent-can-be-used-directly-without-ai.md -->
:::

## Wikipedia Research Example

The browser use agent excels at research tasks, navigating between pages and gathering information:

<<< @/../test/agents/browser_agent_test.rb#wikipedia_research_example {ruby:line-numbers}

::: details Wikipedia Research Response Example
<!-- @include: @/parts/examples/browser-agent-test.rb-test-browser-agent-researches-a-topic-on-wikipedia.md -->
:::

## Area Screenshot Example

Take screenshots of specific page regions:

<<< @/../test/agents/browser_agent_test.rb#area_screenshot_example {ruby:line-numbers}

::: details Area Screenshot Response Example
<!-- @include: @/parts/examples/browser-agent-test.rb-test-browser-agent-takes-area-screenshot.md -->
:::

## Main Content Auto-Cropping

The browser use agent can automatically detect and crop to main content areas:

<<< @/../test/agents/browser_agent_test.rb#main_content_crop_example {ruby:line-numbers}

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
    response = BrowserAgent.with(
      message: params[:instructions],
      url: params[:url]
    ).prompt_context.generate_now
    
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