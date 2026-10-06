# frozen_string_literal: true

module ActionAgent
  # Used to drive a sandbox's running browser from the engine itself, for the
  # steps no model takes: opening the app at a project's start URL, and
  # signing in with credentials the model never sees (BrowserSignIn).
  #
  # It talks to the browser's MCP endpoint in an MCP session of its own,
  # which drives the same tab as an agent's session. Its calls are not agent
  # tool calls, so they are neither traced nor recorded as actions; the
  # browser's own recording masks what is typed.
  class SandboxBrowserDriver
    class Error < StandardError; end

    # The line Playwright MCP reports a page's address on.
    PAGE_URL = /^- Page URL: (\S+)/

    # @raise [Error] when the sandbox's browser is not running
    def initialize(sandbox)
      @sandbox = sandbox
      entry = sandbox.browser_server_entry or raise Error, "The sandbox's browser is not running"
      @client = MCPClient.new(url: entry[:url], label: entry[:name], headers: entry[:headers] || {})
    end

    # Calls +tool+ and returns its text. With +log_arguments+ false the
    # arguments' values are left out of the log.
    #
    # @raise [Error] when the tool fails or the browser does not answer
    # @return [String]
    def call(tool, arguments = {}, log_arguments: true)
      result = @client.call_tool(tool.to_s, arguments, log_arguments: log_arguments)
      raise Error, "#{tool} failed in the sandbox's browser" if result[:is_error]

      result[:text].to_s
    rescue MCPClient::Error => e
      raise Error, "The sandbox's browser did not answer #{tool}: #{e.class}"
    end

    # Opens +path+ (a path on the sandbox's app) and returns the page URL
    # the browser reports, or nil.
    def open(path)
      page_url(call("browser_navigate", { url: path.to_s.presence || "/" }))
    end

    # Runs +function+, the source of a JavaScript function taking no
    # arguments, in the page and returns what it returned, parsed from JSON
    # (nil when it returned nothing readable).
    def evaluate(function)
      text = call("browser_evaluate", { function: function })
      json = text[/^### Result\n(.*?)(?=\n### |\z)/m, 1]
      json && JSON.parse(json.strip)
    rescue JSON::ParserError
      nil
    end

    # Types +text+ into the element +selector+ names, a CSS selector. The
    # text is a credential, so it is never logged.
    def type(selector, text, submit: false)
      call("browser_type", { target: selector, text: text, submit: submit }, log_arguments: false)
      nil
    end

    def click(selector)
      call("browser_click", { target: selector })
      nil
    end

    # The path of the page the browser shows, or nil.
    def current_path
      path = evaluate("() => location.pathname")
      path.is_a?(String) ? path : nil
    end

    def wait(seconds)
      call("browser_wait_for", { time: seconds })
      nil
    end

    private

    def page_url(text)
      text[PAGE_URL, 1]
    end
  end
end
