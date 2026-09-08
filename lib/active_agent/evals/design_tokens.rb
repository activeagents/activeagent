# frozen_string_literal: true

module ActiveAgent
  module Evals
    # The dashboard's design tokens as Ruby, so the self-contained HTML report
    # paints with the same palette as the mounted dashboard without loading
    # its stylesheet.
    #
    # Mirrors actionagent/frontend/tokens.css: LIGHT is the `.aa-dashboard`
    # block, DARK the overrides in `.aa-dashboard.theme-dark`. A test asserts
    # the two files stay in step — change a value in both places.
    module DesignTokens
      FONT_TEXT = '"Inter Variable", Inter, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif'
      FONT_MONO = '"JetBrains Mono", "SF Mono", "Fira Code", Menlo, Consolas, "Courier New", monospace'

      LIGHT = {
        # Brand
        "--color-accent" => "#FA343B",
        "--color-accent-hover" => "#E02D33",
        "--color-accent-b" => "#FA343B29",
        "--color-accent-b-hover" => "#FA343B33",
        "--color-on-accent" => "#ffffff",
        "--color-accent-ui" => "#ef4444",
        "--color-accent-ui-hover" => "#dc2626",
        "--color-accent-ui-muted" => "rgba(239, 68, 68, 0.15)",
        "--color-accent-ui-tint" => "#fef2f2",

        # Surfaces
        "--color-background" => "#f9fafb",
        "--color-background-page" => "#ffffff",
        "--color-surface" => "#ffffff",
        "--color-card" => "#ffffff",
        "--color-muted" => "#f3f4f6",
        "--color-hover" => "#f3f4f6",
        "--color-background-blur" => "rgba(255,255,255,0.9)",

        # Borders
        "--color-border" => "#e5e7eb",
        "--color-border-light" => "#f3f4f6",
        "--color-border-strong" => "#d1d5db",

        # Text
        "--color-text-primary" => "#111827",
        "--color-text-secondary" => "#6b7280",
        "--color-text-muted" => "#9ca3af",
        "--color-text-cell" => "#4b5563",

        # Semantic status
        "--color-success" => "#16a34a",
        "--color-success-soft" => "#dcfce7",
        "--color-success-text" => "#166534",
        "--color-warning" => "#eab308",
        "--color-warning-soft" => "#fef9c3",
        "--color-warning-text" => "#854d0e",
        "--color-error" => "#dc2626",
        "--color-error-soft" => "#fee2e2",
        "--color-error-text" => "#991b1b",
        "--color-info" => "#3b82f6",
        "--color-info-soft" => "#dbeafe",
        "--color-info-text" => "#1e40af",

        # Trace span colors (observability)
        "--span-root" => "#9ca3af",
        "--span-prompt" => "#60a5fa",
        "--span-generate" => "#a855f7",
        "--span-llm" => "#ef4444",
        "--span-thinking" => "#fbbf24",
        "--span-tool" => "#22c55e",
        "--span-response" => "#2dd4bf",

        # Token flow colors
        "--color-token-in" => "#2563eb",
        "--color-token-out" => "#7c3aed",

        # Chart / agent palette
        "--chart-1" => "#6366f1",
        "--chart-2" => "#10b981",
        "--chart-3" => "#f59e0b",
        "--chart-4" => "#ec4899",
        "--chart-5" => "#3b82f6",

        # Type
        "--font-text" => FONT_TEXT,
        "--font-mono" => FONT_MONO
      }.freeze

      DARK = {
        "--color-accent-ui-tint" => "rgba(239, 68, 68, 0.15)",

        "--color-background" => "#0f0f0f",
        "--color-background-page" => "#0f0f0f",
        "--color-surface" => "#1a1a1a",
        "--color-card" => "rgba(255,255,255,0.05)",
        "--color-muted" => "rgba(255,255,255,0.05)",
        "--color-hover" => "#252525",
        "--color-background-blur" => "rgba(15,15,15,0.9)",

        "--color-border" => "rgba(255,255,255,0.1)",
        "--color-border-light" => "rgba(255,255,255,0.05)",
        "--color-border-strong" => "rgba(255,255,255,0.2)",

        "--color-text-primary" => "#ffffff",
        "--color-text-secondary" => "rgba(255,255,255,0.6)",
        "--color-text-muted" => "rgba(255,255,255,0.4)",
        "--color-text-cell" => "rgba(255,255,255,0.7)",

        "--color-success-soft" => "rgba(22,163,74,0.15)",
        "--color-success-text" => "#4ade80",
        "--color-warning-soft" => "rgba(234,179,8,0.15)",
        "--color-warning-text" => "#facc15",
        "--color-error-soft" => "rgba(220,38,38,0.15)",
        "--color-error-text" => "#f87171",
        "--color-info-soft" => "rgba(59,130,246,0.15)",
        "--color-info-text" => "#93c5fd"
      }.freeze

      # One CSS rule declaring `tokens` as custom properties on `scope`, with
      # an optional `color-scheme` so form controls and scrollbars follow:
      #
      #   DesignTokens.css(scope: ":root")                                        # light
      #   DesignTokens.css(scope: ":root.theme-dark", tokens: DesignTokens::DARK,
      #                    color_scheme: "dark")                                  # dark overrides
      def self.css(scope:, tokens: LIGHT, color_scheme: nil)
        declarations = tokens.map { |name, value| "  #{name}: #{value};" }
        declarations.unshift("  color-scheme: #{color_scheme};") if color_scheme
        "#{scope} {\n#{declarations.join("\n")}\n}"
      end
    end
  end
end
