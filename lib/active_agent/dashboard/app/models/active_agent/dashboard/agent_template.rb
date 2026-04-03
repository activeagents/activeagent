# frozen_string_literal: true

module ActiveAgent
  module Dashboard
    # Pre-built agent templates for quick agent creation.
    #
    # Templates provide starting configurations for common use cases like
    # code assistance, research, writing, and browser automation.
    #
    # @example Creating an agent from a template
    #   template = ActiveAgent::Dashboard::AgentTemplate.find_by(slug: "code-assistant")
    #   agent = template.create_agent_for(user)
    #
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

      # Create an agent from this template for a user/account
      def create_agent_for(owner, name: nil)
        agent_class = ActiveAgent::Dashboard::Agent

        agent = agent_class.new(
          name: name || self.name,
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

        # Set owner based on mode
        if ActiveAgent::Dashboard.multi_tenant? && owner.respond_to?(:id)
          agent.account = owner
        elsif owner.respond_to?(:id)
          agent.user = owner if agent.respond_to?(:user=)
        end

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
            featured: true,
            free_tier: true
          },
          {
            name: "Research Assistant",
            slug: "research-assistant",
            description: "Helps research topics, summarize information, and organize findings.",
            category: "research",
            provider: "anthropic",
            model: "claude-sonnet-4-20250514",
            preset_type: "research",
            appearance: { hat: "safari", heldItem: "magnifyingGlass" },
            instruction_sets: %w[github python],
            tools: %w[fetch search memory],
            model_config: { temperature: 0.5 },
            instructions: "You are a thorough research assistant. Help users by:\n- Searching for relevant information\n- Summarizing complex topics\n- Organizing findings into clear reports\n- Identifying key insights and patterns\n\nAlways cite sources when available and distinguish between facts and opinions.",
            icon: "🔍",
            featured: true,
            free_tier: true
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
            featured: true,
            free_tier: true
          },
          {
            name: "Browser Automation",
            slug: "browser-automation",
            description: "Automates web browsing tasks like form filling, data extraction, and testing.",
            category: "automation",
            provider: "anthropic",
            model: "claude-sonnet-4-20250514",
            preset_type: "playwright",
            appearance: { hat: "fedora", hatAccessory: "theaterMasks", heldItem: "browser" },
            instruction_sets: %w[typescript],
            tools: %w[playwright filesystem],
            model_config: { temperature: 0.2 },
            instructions: "You are a browser automation specialist. Help users by:\n- Navigating web pages\n- Filling out forms\n- Extracting data from websites\n- Testing web applications\n\nAlways wait for page loads and handle errors gracefully.",
            icon: "🎭",
            featured: false,
            free_tier: true
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
            featured: true,
            free_tier: true
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
            featured: false,
            free_tier: true
          },
          {
            name: "PlaywrightMCP Demo",
            slug: "playwright-mcp-demo",
            description: "Free browser automation demo using Playwright MCP. Navigate sites, take screenshots, and extract content.",
            category: "automation",
            provider: "anthropic",
            model: "claude-sonnet-4-20250514",
            preset_type: "playwright",
            appearance: { hat: "fedora", hatAccessory: "theaterMasks", heldItem: "browser" },
            instruction_sets: [],
            tools: %w[playwright],
            mcp_servers: {
              playwright: {
                command: "npx",
                args: [ "-y", "@anthropic/mcp-server-playwright" ]
              }
            },
            model_config: { temperature: 0.2, max_tokens: 4096 },
            instructions: "You are a browser automation assistant using Playwright MCP.\n\nAvailable actions:\n- browser_navigate: Go to a URL\n- browser_snapshot: Get the accessibility tree\n- browser_click: Click on an element\n- browser_type: Type text into an input\n- browser_take_screenshot: Capture the page\n- browser_wait_for: Wait for text or element\n\nGuidelines:\n1. Always take a snapshot first to understand the page\n2. Use element refs from snapshots for interactions\n3. Wait for page loads before taking actions\n4. Handle errors gracefully\n5. Limit yourself to 10 steps maximum\n\nAlways describe what you see and what actions you're taking.",
            icon: "🎭",
            featured: true,
            free_tier: true
          }
        ]

        templates.each do |template_attrs|
          find_or_create_by!(slug: template_attrs[:slug]) do |t|
            t.assign_attributes(template_attrs)
          end
        end
      end
    end
  end
end
