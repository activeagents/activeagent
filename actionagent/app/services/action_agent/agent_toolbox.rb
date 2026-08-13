# frozen_string_literal: true

module ActionAgent
  require "resolv"

  # Server-executable tools for platform generation runs, keyed by the tool
  # names an Agent enables in the builder (Agent::AVAILABLE_TOOLS).
  #
  # AgentExecutionService exposes each supported tool to the provider as a
  # function-calling schema and routes invocations here, so real runs produce
  # tool-call roundtrips that show up as :tool spans in Traces, tool messages
  # in Interactions, and tool counts in Metrics.
  #
  # Only tools with a safe server-side implementation are mapped; anything
  # else an agent enables (terminal, playwright, ...) is ignored for platform
  # execution.
  class AgentToolbox
    FETCH_LIMIT_BYTES = 50_000
    FETCH_TIMEOUT_SECONDS = 5

    # agent tool name => function-calling tool definitions (common format).
    DEFINITIONS = {
      "fetch" => [
        {
          name: "fetch_url",
          description: "Fetch a public http(s) URL and return the beginning of its body as text. Use for reading web pages or APIs.",
          parameters: {
            type: "object",
            properties: {
              url: { type: "string", description: "Absolute http(s) URL to fetch" }
            },
            required: [ "url" ]
          }
        }
      ],
      "playwright" => [
        {
          name: "browse_page",
          description: "Browse a page on the trusted documentation site (docs.activeagents.ai). Returns the page's readable text plus a links list of same-site paths with their link text. To follow (\"click\") a link, call browse_page again with its path. Start at \"/\" and navigate only via paths from the links list — do not invent paths.",
          parameters: {
            type: "object",
            properties: {
              url: { type: "string", description: "URL or path on docs.activeagents.ai" }
            },
            required: [ "url" ]
          }
        }
      ],
      # A real browser via a Playwright MCP server (PlaywrightMcpClient).
      # Stateful: navigate changes what snapshot/click see, so these bypass
      # the toolbox result cache.
      "playwright_mcp" => [
        {
          name: "browser_navigate",
          description: "Open a URL in the managed browser. Returns a text snapshot of the page with element refs.",
          parameters: {
            type: "object",
            properties: {
              url: { type: "string", description: "Absolute http(s) URL to open" }
            },
            required: [ "url" ]
          }
        },
        {
          name: "browser_snapshot",
          description: "Accessibility snapshot of the current browser page: its readable structure, with element refs usable by browser_click.",
          parameters: { type: "object", properties: {}, required: [] }
        },
        {
          name: "browser_click",
          description: "Click an element from the latest snapshot by its ref (e.g. e12). Returns the updated page snapshot.",
          parameters: {
            type: "object",
            properties: {
              ref: { type: "string", description: "Element ref from the snapshot" },
              element: { type: "string", description: "Human-readable description of the element" }
            },
            required: [ "ref" ]
          }
        }
      ],
      # Subject-bound like memory: routed by AgentExecutionService (needs the
      # calling agent's account scope), so NOT in FUNCTIONS below.
      "agents" => [
        {
          name: "call_agent",
          description: "Delegate a task to another agent in this workspace and return its reply. Use when another agent has tools, memory, or expertise this task needs.",
          parameters: {
            type: "object",
            properties: {
              slug: { type: "string", description: "The slug of the agent to call, e.g. local-qwen-assistant" },
              message: { type: "string", description: "The task or question for that agent" }
            },
            required: [ "slug", "message" ]
          }
        }
      ],
      "search" => [
        {
          name: "web_search",
          description: "Search the web (DuckDuckGo instant answers) and return a short summary with related topics.",
          parameters: {
            type: "object",
            properties: {
              query: { type: "string", description: "The search query" }
            },
            required: [ "query" ]
          }
        }
      ],
      "code" => [
        {
          name: "calculate",
          description: "Evaluate an arithmetic expression (+, -, *, /, %, parentheses) and return the numeric result.",
          parameters: {
            type: "object",
            properties: {
              expression: { type: "string", description: "Arithmetic expression, e.g. (2 + 3) * 4.5" }
            },
            required: [ "expression" ]
          }
        }
      ],
      # Memory tools mirror solid_agent's HasMemory contract. They are NOT in
      # FUNCTIONS below — execution is subject-bound, so AgentExecutionService
      # routes them to the run's AgentMemory instead of this module.
      "memory" => [
        {
          name: "save_memory",
          description: "Persist a short summary note to long-term memory. Use for facts, decisions, task outcomes, or anything a future agent or session should know. Keep each note self-contained.",
          parameters: {
            type: "object",
            properties: {
              content: { type: "string", description: "The summary note to remember" },
              category: { type: "string", description: "Optional label, e.g. fact, task, handoff" }
            },
            required: [ "content" ]
          }
        },
        {
          name: "recall_memory",
          description: "Read back previously saved memory notes for the current subject, most recent first. Use before starting work to pick up prior context or another agent's handoff.",
          parameters: {
            type: "object",
            properties: {
              category: { type: "string", description: "Only return notes with this label" },
              limit: { type: "integer", description: "Maximum notes to return (default 20)" }
            },
            required: []
          }
        }
      ]
    }.freeze

    # Function name => implementation method, for routing tool calls.
    FUNCTIONS = {
      "fetch_url" => :fetch_url,
      "web_search" => :web_search,
      "calculate" => :calculate,
      "browse_page" => :browse_page,
      "browser_navigate" => :browser_navigate,
      "browser_snapshot" => :browser_snapshot,
      "browser_click" => :browser_click
    }.freeze

    # Stateful tools whose results must never be replayed from cache.
    UNCACHED_FUNCTIONS = %w[browser_navigate browser_snapshot browser_click].freeze

    # Hosts browse_page may fetch — the platform's own trusted docs.
    BROWSE_ALLOWED_HOSTS = %w[docs.activeagents.ai].freeze

    class << self
      # Tool definitions for the subset of an agent's enabled tools that have
      # server-side implementations.
      def definitions_for(tool_names)
        Array(tool_names).flat_map { |name| DEFINITIONS[name.to_s] || [] }
      end

      def function?(name)
        FUNCTIONS.key?(name.to_s)
      end

      # Executes a tool call. Returns a result hash; errors are returned as
      # { error: ... } so the model can react instead of the run crashing.
      #
      # Results are cached by (tool, args) with a short TTL — repeated
      # interactions replay the persisted result (tagged cached: true)
      # instead of re-running the side effect.
      def call(name, **kwargs)
        return { error: "Unknown tool: #{name}" } unless function?(name)
        return public_send(FUNCTIONS.fetch(name.to_s), **kwargs) if UNCACHED_FUNCTIONS.include?(name.to_s)

        cached_fetch(name, kwargs) do
          public_send(FUNCTIONS.fetch(name.to_s), **kwargs)
        end
      rescue ArgumentError => e
        { error: "Invalid arguments for #{name}: #{e.message}" }
      rescue StandardError => e
        Rails.logger.warn("[AgentToolbox] #{name} failed: #{e.class} - #{e.message}")
        { error: "#{name} failed: #{e.message}" }
      end

      MAX_REDIRECTS = 3

      def fetch_url(url:)
        uri = URI.parse(url.to_s)
        return { error: "Only http(s) URLs are supported" } unless uri.is_a?(URI::HTTP)
        return { error: "URL host is not allowed" } unless public_host?(uri.host)

        response = nil
        (MAX_REDIRECTS + 1).times do
          response = Net::HTTP.start(
            uri.host, uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: FETCH_TIMEOUT_SECONDS,
            read_timeout: FETCH_TIMEOUT_SECONDS
          ) { |http| http.get(uri.request_uri.presence || "/", { "User-Agent" => "ActiveAgents-Toolbox/1.0" }) }

          break unless response.is_a?(Net::HTTPRedirection) && response["Location"].present?

          uri = URI.join(uri, response["Location"])
          return { error: "Only http(s) URLs are supported" } unless uri.is_a?(URI::HTTP)
          return { error: "Redirected to a disallowed host" } unless public_host?(uri.host)
        end

        body = response.body.to_s.byteslice(0, FETCH_LIMIT_BYTES).to_s.scrub
        {
          url: uri.to_s,
          status: response.code.to_i,
          content_type: response["Content-Type"],
          body: body,
          truncated: response.body.to_s.bytesize > FETCH_LIMIT_BYTES
        }
      rescue URI::InvalidURIError
        { error: "Invalid URL" }
      end

      def web_search(query:)
        uri = URI("https://api.duckduckgo.com/?#{URI.encode_www_form(q: query.to_s, format: "json", no_html: 1, skip_disambig: 1)}")
        response = Net::HTTP.start(
          uri.host, uri.port,
          use_ssl: true, open_timeout: FETCH_TIMEOUT_SECONDS, read_timeout: FETCH_TIMEOUT_SECONDS
        ) { |http| http.get(uri.request_uri) }
        data = JSON.parse(response.body)

        {
          query: query,
          abstract: data["AbstractText"].presence,
          answer: data["Answer"].presence,
          heading: data["Heading"].presence,
          related_topics: Array(data["RelatedTopics"]).first(5).filter_map { |topic| topic["Text"] }
        }
      end

      def calculate(expression:)
        { expression: expression, result: Calculator.evaluate(expression.to_s) }
      rescue Calculator::Error => e
        { error: e.message }
      end

      # Trusted-docs browser: fetch_url restricted to BROWSE_ALLOWED_HOSTS,
      # with HTML reduced to readable text so small models aren't drowned in
      # markup. Accepts bare paths ("/docs/agents") against the docs host.
      # Resolves a bare path ("/docs/agents") to an absolute URL on the
      # trusted docs host, so the fetched URL is unambiguous everywhere it is
      # recorded (spans, run events, persisted tool arguments).
      def resolve_browse_url(url)
        url = url.to_s
        return url if url.match?(%r{\Ahttps?://})

        "https://#{BROWSE_ALLOWED_HOSTS.first}#{url.start_with?('/') ? url : "/#{url}"}"
      end

      PLAYWRIGHT_RESULT_LIMIT = 8_000

      def browser_navigate(url:)
        playwright_mcp("browser_navigate", { url: url })
      end

      def browser_snapshot
        playwright_mcp("browser_snapshot", {})
      end

      def browser_click(ref:, element: nil)
        playwright_mcp("browser_click", { ref: ref, element: element || ref })
      end

      SNAPSHOT_LINK = /\[Snapshot\]\(([^)]+)\)/

      def playwright_mcp(tool, arguments, retried: false)
        result = PlaywrightMcpClient.instance.call_tool(tool, arguments)
        text = inline_snapshot(result[:text].to_s)
        if text.length > PLAYWRIGHT_RESULT_LIMIT
          text = "#{text[0, PLAYWRIGHT_RESULT_LIMIT]}\n…(truncated, #{text.length} chars total)"
        end
        result[:is_error] ? { error: text.presence || "browser tool failed" } : { text: text }
      rescue PlaywrightMcpClient::Error => e
        # One fresh-session retry: the first call after a server (re)start can
        # race the browser launch.
        unless retried
          PlaywrightMcpClient.reset!
          return playwright_mcp(tool, arguments, retried: true)
        end
        { error: e.message }
      end

      # The MCP server saves page snapshots to files; when it runs beside the
      # app with its output dir on a shared path, read them back so the model
      # sees the page inline.
      def inline_snapshot(text)
        match = SNAPSHOT_LINK.match(text)
        return text unless match

        file = Rails.root.join(".playwright-mcp", File.basename(match[1]))
        return text unless File.exist?(file)

        "#{text}\n\n### Page snapshot\n#{File.read(file)}"
      end

      def browse_page(url:)
        url = resolve_browse_url(url)
        host = URI.parse(url.to_s).host
        unless BROWSE_ALLOWED_HOSTS.include?(host)
          return { error: "browse_page is limited to trusted hosts: #{BROWSE_ALLOWED_HOSTS.join(', ')}" }
        end

        result = fetch_url(url: url)
        return result if result[:error]

        # A redirect may not stay on the trusted host — re-check after fetch.
        final_host = URI.parse(result[:url].to_s).host
        unless BROWSE_ALLOWED_HOSTS.include?(final_host)
          return { error: "Page redirected off the trusted docs host (#{final_host})" }
        end

        if result[:status] == 404
          return {
            url: result[:url], status: 404,
            error: "Page not found. Don't guess paths — browse '/' and follow the paths in the result's links list."
          }
        end

        links = extract_links(result[:body].to_s, result[:url])

        text = result[:body].to_s
          .gsub(%r{<(script|style)[^>]*>.*?</\1>}mi, " ")
          .gsub(/<[^>]+>/, " ")
          .then { |stripped| CGI.unescapeHTML(stripped) }
          .gsub(/\s*\n\s*/, "\n")
          .gsub(/[ \t]+/, " ")
          .gsub(/\n{2,}/, "\n")
          .strip

        {
          url: result[:url], status: result[:status],
          text: text.byteslice(0, 20_000).to_s.scrub,
          links: links,
          truncated: result[:truncated] || text.bytesize > 20_000
        }
      rescue URI::InvalidURIError
        { error: "Invalid URL" }
      end

      BROWSE_LINK_LIMIT = 40

      # Same-site links from the page HTML, so the model can navigate by
      # following real paths instead of guessing them. "Clicking" a link is
      # calling browse_page with its path.
      def extract_links(html, base_url)
        base = URI.parse(base_url.to_s)
        links = html.scan(%r{<a\s[^>]*href=["']([^"'\s]+)["'][^>]*>(.*?)</a>}mi).filter_map do |href, inner|
          next if href.start_with?("javascript:", "mailto:", "tel:", "data:", "#")

          resolved = begin
            URI.join(base, href)
          rescue URI::Error
            next
          end
          next unless resolved.is_a?(URI::HTTP) && BROWSE_ALLOWED_HOSTS.include?(resolved.host)

          text = CGI.unescapeHTML(inner.gsub(/<[^>]+>/, " ")).gsub(/\s+/, " ").strip
          entry = { path: resolved.request_uri }
          entry[:text] = text.byteslice(0, 80).to_s.scrub if text.present?
          entry
        end
        links.uniq { |link| link[:path] }.first(BROWSE_LINK_LIMIT)
      rescue URI::Error
        []
      end

      private

      CACHE_TTL = 5.minutes

      # Uses SolidAgent::ToolCache when the installed solid_agent provides it
      # (it carries the canonical key scheme + error-skipping semantics);
      # falls back to an equivalent Rails.cache fetch on older gem versions.
      def cached_fetch(name, kwargs, &block)
        if defined?(SolidAgent::ToolCache)
          SolidAgent::ToolCache.fetch(tool: name.to_s, args: kwargs, ttl: CACHE_TTL, &block)
        else
          key = "solid_agent:tool_cache:#{name}:#{Digest::SHA256.hexdigest(kwargs.sort.to_h.to_json)}"
          cached = Rails.cache.read(key)
          return cached.merge(cached: true) unless cached.nil?

          result = block.call
          unless result.respond_to?(:key?) && (result.key?(:error) || result.key?("error"))
            Rails.cache.write(key, result, expires_in: CACHE_TTL)
          end
          result
        end
      end

      # SSRF guard for fetch_url: reject hosts that resolve to loopback,
      # private, or link-local addresses.
      def public_host?(host)
        return false if host.blank?

        addresses = Resolv.getaddresses(host)
        return false if addresses.empty?

        addresses.all? do |address|
          ip = IPAddr.new(address)
          !(ip.loopback? || ip.private? || ip.link_local?)
        end
      rescue IPAddr::InvalidAddressError, Resolv::ResolvError
        false
      end
    end

    # Minimal recursive-descent arithmetic evaluator (no eval).
    # Grammar: expr := term (('+'|'-') term)*; term := factor (('*'|'/'|'%') factor)*;
    # factor := '-'? (number | '(' expr ')')
    module Calculator
      class Error < StandardError; end

      module_function

      def evaluate(expression)
        tokens = tokenize(expression)
        result, rest = parse_expr(tokens)
        raise Error, "Unexpected input: #{rest.join(' ')}" unless rest.empty?

        result = result.to_f
        result % 1 == 0 ? result.to_i : result.round(10)
      end

      def tokenize(expression)
        tokens = expression.scan(%r{\d+(?:\.\d+)?|[-+*/%()]|\S})
        invalid = tokens.grep_v(%r{\A(?:\d+(?:\.\d+)?|[-+*/%()])\z})
        raise Error, "Unsupported characters: #{invalid.uniq.join(' ')}" if invalid.any?
        raise Error, "Empty expression" if tokens.empty?

        tokens
      end

      def parse_expr(tokens)
        value, tokens = parse_term(tokens)
        while tokens.first == "+" || tokens.first == "-"
          op = tokens.shift
          rhs, tokens = parse_term(tokens)
          value = op == "+" ? value + rhs : value - rhs
        end
        [ value, tokens ]
      end

      def parse_term(tokens)
        value, tokens = parse_factor(tokens)
        while [ "*", "/", "%" ].include?(tokens.first)
          op = tokens.shift
          rhs, tokens = parse_factor(tokens)
          raise Error, "Division by zero" if rhs.zero? && op != "*"
          value = case op
          when "*" then value * rhs
          when "/" then value / rhs
          else value % rhs
          end
        end
        [ value, tokens ]
      end

      def parse_factor(tokens)
        raise Error, "Unexpected end of expression" if tokens.empty?

        if tokens.first == "-"
          tokens.shift
          value, tokens = parse_factor(tokens)
          return [ -value, tokens ]
        end

        token = tokens.shift
        if token == "("
          value, tokens = parse_expr(tokens)
          raise Error, "Missing closing parenthesis" unless tokens.shift == ")"
          [ value, tokens ]
        elsif token =~ /\A\d/
          [ token.include?(".") ? token.to_f : Rational(token), tokens ]
        else
          raise Error, "Unexpected token: #{token}"
        end
      end
    end
  end
end
