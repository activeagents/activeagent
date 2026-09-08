# frozen_string_literal: true

require "test_helper"

# The evaluation report paints with ActiveAgent::Evals::DesignTokens; the
# mounted dashboard paints with actionagent/frontend/tokens.css. Both must
# carry the same values, so a token changed in one place fails here with the
# names that drifted.
class EvalsDesignTokensParityTest < ActiveSupport::TestCase
  Tokens = ActiveAgent::Evals::DesignTokens
  TOKENS_CSS = File.expand_path("../../actionagent/frontend/tokens.css", __dir__)

  def setup
    skip "#{TOKENS_CSS} is not in this checkout" unless File.exist?(TOKENS_CSS)
  end

  def test_light_tokens_match_the_dashboard_root
    assert_tokens_match css_declarations(".aa-dashboard"), Tokens::LIGHT, ".aa-dashboard"
  end

  def test_dark_overrides_match_the_dashboard_dark_theme
    assert_tokens_match css_declarations(".aa-dashboard.theme-dark"), Tokens::DARK, ".aa-dashboard.theme-dark"
  end

  def test_every_color_token_is_covered
    assert_operator Tokens::LIGHT.keys.grep(/\A--color-/).size, :>=, 30
    assert Tokens::DARK.keys.all? { |name| Tokens::LIGHT.key?(name) }, "every dark override overrides a light token"
    assert_equal Tokens::FONT_TEXT, Tokens::LIGHT["--font-text"]
    assert_equal Tokens::FONT_MONO, Tokens::LIGHT["--font-mono"]
  end

  def test_css_helper_declares_the_tokens_on_the_scope
    light = Tokens.css(scope: ":root", color_scheme: "light")
    dark = Tokens.css(scope: ":root.theme-dark", tokens: Tokens::DARK, color_scheme: "dark")

    assert_match(/\A:root \{\n  color-scheme: light;\n  --color-accent: #FA343B;\n/, light)
    assert_includes light, "  --font-mono: #{Tokens::FONT_MONO};\n"
    assert_match(/\A:root\.theme-dark \{\n  color-scheme: dark;\n/, dark)
    assert_includes dark, "  --color-text-primary: #ffffff;\n"
    assert_not_includes dark, "--color-accent:"
    assert_match(/\}\z/, dark)
  end

  private

  # The custom properties declared in the `selector { ... }` block of tokens.css.
  def css_declarations(selector)
    css = File.read(TOKENS_CSS)
    body = css[/^#{Regexp.escape(selector)}\s*\{(.*?)^\}/m, 1]
    assert body, "#{selector} block not found in #{TOKENS_CSS}"
    body.scan(/^\s*(--[\w-]+)\s*:\s*(.+?);\s*$/).to_h
  end

  def assert_tokens_match(css, ruby, scope)
    differing = (css.keys | ruby.keys).reject { |name| css[name] == ruby[name] }
    details = differing.map { |name| "#{name} (css: #{css[name].inspect}, ruby: #{ruby[name].inspect})" }
    assert_empty differing, "tokens differ between #{scope} and DesignTokens: #{details.join(', ')}"
    assert_operator css.size, :>, 0
  end
end
