/**
 * Design Tokens and TUI-Compatible Utilities
 *
 * Philosophy:
 * - Clean, data-focused interface
 * - ASCII/Unicode characters that render in terminals
 * - Monospace-friendly layouts for future TUI rendering
 * - Semantic color usage with limited palette
 */

// ============================================================================
// ICONS - ASCII/Unicode characters that work in TUI
// ============================================================================
export const ICONS = {
  // Navigation / Structure
  chevronRight: '>',
  chevronDown: 'v',
  chevronUp: '^',
  arrow: '->',
  arrowLeft: '<-',
  pipe: '|',
  corner: '+',
  branch: '|-',

  // Status
  success: '[+]',
  error: '[!]',
  warning: '[?]',
  info: '[i]',
  pending: '[ ]',
  active: '[*]',

  // Actions
  add: '+',
  remove: '-',
  edit: '*',
  view: '@',
  run: '>',
  stop: 'x',
  refresh: '~',

  // Observability
  trace: '->',
  span: '|',
  metric: '#',
  log: '>',

  // Data types
  agent: '@',
  action: '#',
  time: ':',
  cost: '$',
  tokens: 'T',
  memory: 'M',

  // Navigation items (sidebar)
  nav: {
    agents: '@',
    newAgent: '+',
    demo: '>',
    traces: '->',
    metrics: '#',
    evaluations: '=',
    interactions: '<>',
    benchmarks: '%%',
    replay: '[>]',
    docs: '?',
    github: '*',
  },

  // Span types for traces
  spans: {
    root: '>',
    prompt: '*',
    generate: '|>',
    llm: '>>',
    thinking: '..',
    tool: '[]',
    response: '<|',
  },
};

// ============================================================================
// BOX DRAWING - For TUI-style borders
// ============================================================================
export const BOX = {
  // Single line
  horizontal: '-',
  vertical: '|',
  topLeft: '+',
  topRight: '+',
  bottomLeft: '+',
  bottomRight: '+',
  teeLeft: '+',
  teeRight: '+',
  teeUp: '+',
  teeDown: '+',
  cross: '+',

  // Unicode variants (nicer in terminals that support them)
  unicode: {
    horizontal: '\u2500',     // ─
    vertical: '\u2502',       // │
    topLeft: '\u250C',        // ┌
    topRight: '\u2510',       // ┐
    bottomLeft: '\u2514',     // └
    bottomRight: '\u2518',    // ┘
    teeLeft: '\u251C',        // ├
    teeRight: '\u2524',       // ┤
    teeUp: '\u2534',          // ┴
    teeDown: '\u252C',        // ┬
    cross: '\u253C',          // ┼
  },
};

// ============================================================================
// COLORS - Semantic palette
// ============================================================================
export const COLORS = {
  // Status colors
  success: '#10b981',
  error: '#ef4444',
  warning: '#f59e0b',
  info: '#3b82f6',

  // Agent colors (limited, distinct palette)
  agents: {
    translation: '#6366f1',
    codeReview: '#10b981',
    documentation: '#f59e0b',
    support: '#ec4899',
    dataAnalysis: '#3b82f6',
  },

  // Strategy colors for benchmarks
  strategies: {
    sequential: '#6b7280',
    threads: '#3b82f6',
    threadPool: '#0891b2',
    ractors: '#ef4444',
    ractorPool: '#f97316',
    asyncFibers: '#8b5cf6',
  },

  // UI colors
  accent: '#ef4444',
  accentMuted: 'rgba(239, 68, 68, 0.15)',
};

// ============================================================================
// SPACING - Consistent grid
// ============================================================================
export const SPACING = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  xxl: 32,
};

// ============================================================================
// TYPOGRAPHY
// ============================================================================
export const TYPOGRAPHY = {
  // Use monospace for data display
  mono: "'SF Mono', 'Fira Code', 'Consolas', monospace",

  sizes: {
    xs: '10px',
    sm: '11px',
    base: '13px',
    md: '14px',
    lg: '16px',
    xl: '20px',
    xxl: '24px',
  },

  weights: {
    normal: 400,
    medium: 500,
    semibold: 600,
    bold: 700,
  },
};

// ============================================================================
// THEME UTILITIES
// ============================================================================
export const getThemeColors = (darkMode) => ({
  // Backgrounds
  bg: darkMode ? '#0f0f0f' : '#f9fafb',
  bgCard: darkMode ? 'rgba(0,0,0,0.3)' : '#ffffff',
  bgMuted: darkMode ? 'rgba(255,255,255,0.05)' : '#f3f4f6',
  bgHover: darkMode ? 'rgba(255,255,255,0.1)' : '#f3f4f6',
  bgActive: darkMode ? 'rgba(239, 68, 68, 0.15)' : '#fef2f2',

  // Borders
  border: darkMode ? 'rgba(255,255,255,0.1)' : '#e5e7eb',
  borderStrong: darkMode ? 'rgba(255,255,255,0.2)' : '#d1d5db',

  // Text
  textPrimary: darkMode ? '#ffffff' : '#111827',
  textSecondary: darkMode ? 'rgba(255,255,255,0.7)' : '#4b5563',
  textMuted: darkMode ? 'rgba(255,255,255,0.5)' : '#9ca3af',
  textAccent: '#ef4444',

  // Status
  success: '#10b981',
  error: '#ef4444',
  warning: '#f59e0b',
});

// ============================================================================
// COMPONENT STYLES - Common patterns
// ============================================================================
export const cardStyle = (darkMode) => ({
  background: darkMode ? 'rgba(0,0,0,0.3)' : '#ffffff',
  border: `1px solid ${darkMode ? 'rgba(255,255,255,0.1)' : '#e5e7eb'}`,
  borderRadius: '8px',
});

export const buttonStyle = (darkMode, active = false) => ({
  padding: '6px 12px',
  background: active
    ? '#ef4444'
    : darkMode ? 'rgba(255,255,255,0.1)' : '#f3f4f6',
  color: active
    ? '#ffffff'
    : darkMode ? '#ffffff' : '#374151',
  border: 'none',
  borderRadius: '4px',
  fontSize: '13px',
  fontFamily: TYPOGRAPHY.mono,
  cursor: 'pointer',
});

export const inputStyle = (darkMode) => ({
  padding: '8px 12px',
  background: darkMode ? 'rgba(255,255,255,0.1)' : '#ffffff',
  border: `1px solid ${darkMode ? 'rgba(255,255,255,0.2)' : '#e5e7eb'}`,
  borderRadius: '4px',
  color: darkMode ? '#ffffff' : '#111827',
  fontSize: '13px',
  fontFamily: TYPOGRAPHY.mono,
});

// ============================================================================
// STAT DISPLAY - For metrics/numbers
// ============================================================================
export const statStyle = (darkMode) => ({
  label: {
    fontSize: '10px',
    fontFamily: TYPOGRAPHY.mono,
    color: darkMode ? 'rgba(255,255,255,0.5)' : '#9ca3af',
    textTransform: 'uppercase',
    letterSpacing: '0.05em',
  },
  value: {
    fontSize: '16px',
    fontFamily: TYPOGRAPHY.mono,
    fontWeight: 600,
    color: darkMode ? '#ffffff' : '#111827',
  },
});

// ============================================================================
// TABLE STYLES - Data grid patterns
// ============================================================================
export const tableHeaderStyle = (darkMode) => ({
  fontSize: '10px',
  fontFamily: TYPOGRAPHY.mono,
  fontWeight: 600,
  color: darkMode ? 'rgba(255,255,255,0.5)' : '#6b7280',
  textTransform: 'uppercase',
  letterSpacing: '0.05em',
  padding: '8px 12px',
  borderBottom: `1px solid ${darkMode ? 'rgba(255,255,255,0.1)' : '#e5e7eb'}`,
});

export const tableRowStyle = (darkMode, selected = false) => ({
  padding: '10px 12px',
  background: selected
    ? darkMode ? 'rgba(239, 68, 68, 0.1)' : '#fef2f2'
    : 'transparent',
  borderBottom: `1px solid ${darkMode ? 'rgba(255,255,255,0.05)' : '#f3f4f6'}`,
  cursor: 'pointer',
  fontFamily: TYPOGRAPHY.mono,
  fontSize: '13px',
});
