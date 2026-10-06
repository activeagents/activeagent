# frozen_string_literal: true

module ActionAgent
  # Used to read the mail a sandbox's app sent, such as a sign-up's
  # verification link.
  #
  # A sandbox backend sets DIRECTORY_ENV in the app's environment, and the
  # engine, which every sandbox app bundles, then switches Action Mailer to
  # Mail's file delivery into that directory (see ActionAgent::Engine). File
  # delivery appends each message to one file per recipient address, so the
  # newest message for an address is the last one in its file. The setting
  # lives only in the sandbox's environment, never in the checkout.
  module SandboxMail
    # Raised when the sandbox's backend cannot read its files.
    class Unsupported < StandardError; end

    DIRECTORY_ENV = "ACTION_AGENT_SANDBOX_MAIL_DIR"
    # Where mail is written, relative to the checkout.
    DIRECTORY = "tmp/activeagents/mail"
    ADDRESS = /\A[^\s@\/\\]+@[^\s@\/\\]+\z/
    MAX_TEXT = 4_000
    MAX_LINKS = 20
    LINK = %r{https?://[^\s"'<>()]+}

    module_function

    # The newest message the app sent to +to+ as { subject:, from:, to:,
    # date:, text:, links: [{ url:, path: }] }, scrubbed of +secrets+, or {}
    # when none was sent. Each link's path is its path and query, which the
    # sandbox browser opens on the app whatever host the mail named.
    #
    # @raise [ArgumentError] when +to+ is not an email address
    # @raise [Unsupported] when the backend cannot read the sandbox's files
    # @return [Hash]
    def last_message(sandbox, to:, secrets: [], orchestrator: SandboxOrchestrator.new)
      address = to.to_s.strip
      raise ArgumentError, "to must be an email address" unless address.match?(ADDRESS)
      unless orchestrator.supports?(:read_file)
        raise Unsupported, "The #{orchestrator.backend_name} sandbox backend cannot read the sandbox's mail"
      end

      mailbox = orchestrator.read_file(sandbox, "#{DIRECTORY}/#{address}")
      return {} if mailbox.blank?

      message = parse(last_raw_message(mailbox.to_s.dup.force_encoding(Encoding::BINARY)))
      message ? SecretScrubber.scrub(message, secrets) : {}
    end

    # The last message in +mailbox+, a file Mail's file delivery appended
    # messages to, each followed by a blank line. A message starts with a
    # header line after that blank line (Date, or Return-Path when the app
    # sets one), and its header block carries a Message-ID.
    def last_raw_message(mailbox)
      starts = [ 0 ]
      mailbox.scan(/\r?\n\r?\n(?=[A-Za-z][A-Za-z0-9-]*: )/) { starts << Regexp.last_match.end(0) }
      start = starts.reverse.find do |offset|
        header_end = mailbox.index(/\r?\n\r?\n/, offset) || mailbox.length
        mailbox[offset...header_end].match?(/^Message-ID:/i)
      end
      mailbox[(start || 0)..]
    end

    def parse(raw)
      require "mail"
      mail = Mail.new(raw)
      text = message_text(mail)
      {
        subject: mail.subject.to_s,
        from: Array(mail.from).join(", "),
        to: Array(mail.to).join(", "),
        date: mail.date&.iso8601,
        text: text.truncate(MAX_TEXT),
        links: links(text, mail)
      }
    rescue LoadError
      raise Unsupported, "Reading the sandbox's mail needs the mail gem in the dashboard app"
    rescue StandardError => e
      Rails.logger.warn("[ActionAgent] could not parse a sandbox's mail: #{e.class}")
      nil
    end

    def message_text(mail)
      part = mail.multipart? ? (mail.text_part || mail.html_part) : mail
      body = part&.decoded.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      part&.mime_type.to_s.include?("html") ? html_text(body) : body.strip
    end

    def html_text(html)
      ActionController::Base.helpers.strip_tags(html.gsub(/<(br|\/p|\/div|\/li|\/h\d)[^>]*>/i, "\n")).gsub(/\n{3,}/, "\n\n").strip
    end

    def links(text, mail)
      html = mail.multipart? ? mail.html_part&.decoded.to_s : (mail.mime_type.to_s.include?("html") ? mail.decoded.to_s : "")
      urls = (text.scan(LINK) + html.scan(/href=["'](https?:[^"']+)["']/i).flatten).map { |url| CGI.unescapeHTML(url) }
      urls.uniq.first(MAX_LINKS).map do |url|
        uri = URI.parse(url)
        { url: url, path: [ uri.path.presence || "/", uri.query ].compact.join("?") }
      rescue URI::InvalidURIError
        { url: url, path: nil }
      end
    end
  end
end
