# frozen_string_literal: true

module ActionAgent
  class AgentTemplate < ApplicationRecord
    # Validations
    validates :name, presence: true
    validates :slug, presence: true, uniqueness: true
    validates :category, presence: true

    # Scopes
    scope :featured, -> { where(featured: true) }
    scope :by_category, ->(cat) { where(category: cat) }
    scope :popular, -> { order(usage_count: :desc) }
    scope :public_templates, -> { where(public: true) }
    scope :free_tier, -> { where(free_tier: true) }

    # Categories
    CATEGORIES = %w[
      productivity
      development
      research
      creative
      data
      automation
    ].freeze

    # Build (unsaved) an agent from this template inside +relation+: a host
    # user's agents association, or the engine's owner scope
    # (Api::BaseController#owner_agents). The relation decides the owner —
    # including no owner at all in a single-user install, where the old
    # `user.agents.build` had no user to call it on and raised.
    def build_agent_in(relation, name: nil)
      relation.build(
        name: name.presence || self.name,
        description: description,
        provider: provider,
        model: model,
        instructions: instructions,
        preset_type: preset_type,
        appearance: appearance,
        instruction_sets: instruction_sets,
        tools: tools,
        mcp_servers: mcp_servers,
        model_config: model_config,
        status: :draft
      )
    end

    # Create an agent from this template for a host user with an `agents`
    # association.
    def create_agent_for(user, name: nil)
      agent = build_agent_in(user.agents, name: name)

      if agent.save
        increment!(:usage_count)
      end

      agent
    end

    # Seed default templates
    def self.seed_defaults!
      templates = [
        {
          name: "Code Assistant",
          slug: "code-assistant",
          description: "A helpful coding assistant that can explain code, suggest improvements, and help debug issues.",
          category: "development",
          provider: "openai",
          model: "gpt-4o",
          preset_type: "terminal",
          appearance: { hat: "fedora", heldItem: "terminal" },
          instruction_sets: %w[github ruby rails typescript],
          tools: %w[terminal code filesystem],
          model_config: { temperature: 0.3 },
          instructions: "You are a senior software engineer with expertise in multiple programming languages. Help users with:\n- Code explanations and reviews\n- Debugging issues\n- Suggesting best practices\n- Writing tests\n\nAlways explain your reasoning and provide examples when helpful.",
          icon: "💻",
          featured: true
        },
        {
          name: "Research Assistant",
          slug: "research-assistant",
          description: "Helps research topics, summarize information, and organize findings.",
          category: "research",
          provider: "anthropic",
          model: "claude-sonnet-5",
          preset_type: "research",
          appearance: { hat: "safari", heldItem: "magnifyingGlass" },
          instruction_sets: %w[github python],
          tools: %w[fetch search memory],
          model_config: { temperature: 0.5 },
          instructions: "You are a thorough research assistant. Help users by:\n- Searching for relevant information\n- Summarizing complex topics\n- Organizing findings into clear reports\n- Identifying key insights and patterns\n\nAlways cite sources when available and distinguish between facts and opinions.",
          icon: "🔍",
          featured: true
        },
        {
          name: "Writing Assistant",
          slug: "writing-assistant",
          description: "Helps with writing, editing, and improving text content.",
          category: "creative",
          provider: "openai",
          model: "gpt-4o",
          preset_type: "writing",
          appearance: { hat: "fedora", hatAccessory: "feather", heldItem: "scroll" },
          instruction_sets: [],
          tools: %w[edit translate],
          model_config: { temperature: 0.7 },
          instructions: "You are a skilled writer and editor. Help users with:\n- Writing and editing content\n- Improving clarity and flow\n- Adjusting tone for different audiences\n- Grammar and style corrections\n\nMaintain the author's voice while suggesting improvements.",
          icon: "✍️",
          featured: true
        },
        {
          name: "Browser Automation",
          slug: "browser-automation",
          description: "Automates web browsing tasks like form filling, data extraction, and testing.",
          category: "automation",
          provider: "anthropic",
          model: "claude-sonnet-5",
          preset_type: "playwright",
          appearance: { hat: "fedora", hatAccessory: "theaterMasks", heldItem: "browser" },
          instruction_sets: %w[typescript],
          tools: %w[playwright filesystem],
          model_config: { temperature: 0.2 },
          instructions: "You are a browser automation specialist. Help users by:\n- Navigating web pages\n- Filling out forms\n- Extracting data from websites\n- Testing web applications\n\nAlways wait for page loads and handle errors gracefully.",
          icon: "🎭",
          featured: false
        },
        {
          name: "Data Analyst",
          slug: "data-analyst",
          description: "Analyzes data, creates visualizations, and provides insights.",
          category: "data",
          provider: "openai",
          model: "gpt-4o",
          preset_type: "documentAnalysis",
          appearance: { hat: "fedora", heldItem: "document" },
          instruction_sets: %w[python],
          tools: %w[code database filesystem],
          model_config: { temperature: 0.3 },
          instructions: "You are a data analyst. Help users by:\n- Analyzing datasets\n- Creating visualizations\n- Finding patterns and insights\n- Generating reports\n\nExplain your methodology and provide clear interpretations of results.",
          icon: "📊",
          featured: true
        },
        {
          name: "DevOps Assistant",
          slug: "devops-assistant",
          description: "Helps with infrastructure, deployments, and system administration.",
          category: "development",
          provider: "openai",
          model: "gpt-4o",
          preset_type: "terminal",
          appearance: { hat: "fedora", heldItem: "terminal" },
          instruction_sets: %w[docker kubernetes aws gcp],
          tools: %w[terminal filesystem code],
          model_config: { temperature: 0.2 },
          instructions: "You are a DevOps engineer. Help users with:\n- Infrastructure setup and management\n- CI/CD pipeline configuration\n- Container orchestration\n- Cloud resource management\n\nAlways prioritize security and follow best practices.",
          icon: "🚀",
          featured: false
        },
        {
          name: "Conference Ticket Agent",
          slug: "conference-ticket",
          description: "Registers for a conference in the platform's browser and stops before paying: the run hands the ticket page to a person, who pays. Built for the SF Ruby Conference demo; works on any event page.",
          category: "automation",
          provider: "anthropic",
          model: "claude-sonnet-5",
          preset_type: "playwright",
          appearance: { hat: "fedora", hatAccessory: "theaterMasks", heldItem: "browser" },
          instruction_sets: [],
          # playwright_mcp is the platform's browser (browser_navigate,
          # browser_snapshot, browser_click) plus request_handoff.
          tools: %w[playwright_mcp],
          model_config: { temperature: 0.1, max_tokens: 4096 },
          instructions: <<~INSTRUCTIONS.strip,
            You register a person for a conference in a real browser, and you stop before anything is paid.

            You are given the event URL, the attendee's name and email, and the ticket they want. The person who started this run is watching and pays themselves.

            How to work:
            1. browser_navigate to the event URL, then browser_snapshot to read the page.
            2. Find the tickets or registration link (Tickets, Register, Get ticket, Buy). Ticket pages often live on a ticketing site such as Luma; follow the link.
            3. Choose the ticket you were given. If it is sold out or missing, stop and say so.
            4. Enter only the attendee details you were given: name, email, and anything else the person listed. Leave every other field empty.
            5. Take a browser_snapshot after each step and use element refs from the latest snapshot only.
            6. The moment the page asks for a card number, billing address, a wallet, a password, or a one-time code, call request_handoff with the current URL, what the page is asking for, and the values you entered. Then stop.

            Never enter payment details. Never click Pay, Place order, Confirm purchase or Complete registration. Never accept terms on the person's behalf. Never invent details. Stay on the event's own pages and its ticketing site.

            Report in three lines: where you stopped, what you entered, and what the person does next.
          INSTRUCTIONS
          icon: "🎟️",
          featured: true
        },
        {
          name: "PlaywrightMCP Demo",
          slug: "playwright-mcp-demo",
          description: "Free browser automation demo using Playwright MCP. Navigate sites, take screenshots, and extract content.",
          category: "automation",
          provider: "anthropic",
          model: "claude-sonnet-5",
          preset_type: "playwright",
          appearance: { hat: "fedora", hatAccessory: "theaterMasks", heldItem: "browser" },
          instruction_sets: [],
          tools: %w[playwright],
          # An array of server entries, which is the shape agents.mcp_servers
          # takes everywhere else (the builder's strong params permit an
          # array). The old top-level Hash was copied onto agents verbatim and
          # crashed ToolDiscovery for the whole workspace.
          mcp_servers: [
            {
              name: "playwright",
              command: "npx",
              args: [ "-y", "@playwright/mcp@latest" ]
            }
          ],
          model_config: { temperature: 0.2, max_tokens: 4096 },
          instructions: "You are a browser automation assistant using Playwright MCP.\n\nAvailable actions:\n- browser_navigate: Go to a URL\n- browser_snapshot: Get the accessibility tree\n- browser_click: Click on an element\n- browser_type: Type text into an input\n- browser_take_screenshot: Capture the page\n- browser_wait_for: Wait for text or element\n\nGuidelines:\n1. Always take a snapshot first to understand the page\n2. Use element refs from snapshots for interactions\n3. Wait for page loads before taking actions\n4. Handle errors gracefully\n5. Limit yourself to 10 steps maximum\n\nAlways describe what you see and what actions you're taking.",
          icon: "🎭",
          featured: true,
          free_tier: true
        }
      ]

      templates.each do |template_attrs|
        AgentTemplate.find_or_create_by!(slug: template_attrs[:slug]) do |t|
          t.assign_attributes(template_attrs)
        end
      end
    end
  end
end
