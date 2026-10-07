# frozen_string_literal: true

module ActionAgent
  # Replaces known secrets in text or nested JSON-like data before it is
  # stored or shown: a sandbox's GitHub token and Claude Code credential can
  # surface in a process's output (an error echoing a URL, a session that
  # prints its environment), and none of that may reach a transcript, a log
  # tail or an API response.
  #
  # Besides the values it is given, it masks anything shaped like a GitHub
  # token, given or not. A GitHub App checkout's token is never stored, so a
  # later code session in that checkout cannot name it by value.
  module SecretScrubber
    MASK = "[REDACTED]"
    # Shorter values are not credentials, and masking them would mangle text.
    MIN_SECRET_LENGTH = 8
    # GitHub's token formats: personal (ghp_), OAuth (gho_), App user (ghu_),
    # installation (ghs_) and refresh (ghr_) tokens, and fine-grained
    # personal tokens (github_pat_). Matched wherever they start, so a token
    # straight after a percent-escape (`%3Aghs_…` in an encoded URL) or a
    # name (`GITHUB_TOKEN_ghs_…`) is masked too.
    GITHUB_TOKEN = /gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}/
    CLAUDE_TOKEN = /sk-ant-(?:oat|ort|api)[A-Za-z0-9_-]+/

    module_function

    # @param value [String, Hash, Array, Object] what to scrub
    # @param secrets [Array<String>] the values to mask
    # @return a copy of +value+ with every secret and every GitHub token masked
    def scrub(value, secrets)
      secrets = Array(secrets).compact.map(&:to_s).select { |secret| secret.length >= MIN_SECRET_LENGTH }.uniq

      # Longest first, so a secret that contains another is masked whole.
      pattern = Regexp.union(*secrets.sort_by { |secret| -secret.length }, GITHUB_TOKEN, CLAUDE_TOKEN)
      deep_scrub(value, pattern)
    end

    # +values+ with the other forms each can take in output: URL-encoded (as
    # a form and as a path encode it), Base64 (standard and URL-safe, with
    # and without padding) and escaped inside a JSON string (as JSON.stringify
    # and as Rails' to_json escape it). Blank values are dropped.
    #
    # @param values [Array<String>]
    # @return [Array<String>]
    def with_encodings(values)
      Array(values).compact.map(&:to_s).reject(&:empty?).flat_map do |value|
        base64 = [ value ].pack("m0")
        urlsafe = base64.tr("+/", "-_")
        [ value, URI.encode_www_form_component(value), ERB::Util.url_encode(value),
          base64, base64.delete("="), urlsafe, urlsafe.delete("="),
          JSON.generate(value)[1...-1], value.to_json[1...-1] ]
      end.uniq
    end

    def deep_scrub(value, pattern)
      case value
      # A regexp cannot scan bytes that are invalid in the string's encoding,
      # so those are replaced first.
      when String then (value.valid_encoding? ? value : value.scrub).gsub(pattern, MASK)
      when Hash then value.to_h { |key, item| [ key, deep_scrub(item, pattern) ] }
      when Array then value.map { |item| deep_scrub(item, pattern) }
      else value
      end
    end
  end
end
