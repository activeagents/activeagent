import React from 'react';
import { useTheme } from '../../contexts/ThemeContext';

/**
 * AgentStatCard — the one agent card presentation.
 *
 * Used by the Agents list (/dashboard) and the Traces "agents" view
 * (/dashboard/traces), which previously rendered visually different cards:
 * the list was light-only Tailwind, the traces cards theme-aware inline
 * styles. Same shell, same tile grid, same hover affordance in both, and
 * both now follow the dark-mode toggle.
 *
 * Callers own their metrics — the two surfaces measure different windows —
 * but they render through the same tiles.
 *
 * @param {string} name            agent name or class
 * @param {string} [subtitle]      description / action list
 * @param {node}   [badge]         status pill or call count
 * @param {string} [accentColor]   left border accent (traces palette)
 * @param {Array}  stats           [{ label, value, tone, title }]
 * @param {node}   [footer]        provider/model row
 * @param {func}   [onClick]       whole-card activation
 * @param {node}   [actions]       hover-revealed controls
 */
export default function AgentStatCard({
  name,
  subtitle,
  badge,
  accentColor,
  stats = [],
  footer,
  onClick,
  actions,
}) {
  // Test hook. The e2e suite used to find cards by their Tailwind classes
  // (div.bg-white.rounded-xl); unifying the card onto inline styles silently
  // removed those classes and the locator matched nothing, so the whole
  // scorecard test failed on its first assertion rather than reporting drift.
  // A data-testid survives restyling.
  const { darkMode } = useTheme();
  const [hovered, setHovered] = React.useState(false);

  const palette = {
    cardBg: darkMode ? 'rgba(255,255,255,0.05)' : '#ffffff',
    border: darkMode ? 'rgba(255,255,255,0.1)' : '#e5e7eb',
    borderHover: darkMode ? 'rgba(255,255,255,0.2)' : '#d1d5db',
    tileBg: darkMode ? 'rgba(255,255,255,0.05)' : '#f9fafb',
    textPrimary: darkMode ? '#f9fafb' : '#111827',
    textSecondary: darkMode ? '#9ca3af' : '#6b7280',
    textMuted: darkMode ? '#6b7280' : '#9ca3af',
  };

  const toneColor = (tone) => {
    if (tone === 'good') return darkMode ? '#4ade80' : '#16a34a';
    if (tone === 'warn') return darkMode ? '#facc15' : '#ca8a04';
    if (tone === 'bad') return darkMode ? '#f87171' : '#dc2626';
    if (tone === 'muted') return palette.textMuted;
    return palette.textPrimary;
  };

  return (
    <div
      data-testid="agent-card"
      data-agent-name={typeof name === 'string' ? name : undefined}
      onClick={onClick}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      role={onClick ? 'button' : undefined}
      tabIndex={onClick ? 0 : undefined}
      onKeyDown={(e) => {
        if (!onClick) return;
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          onClick(e);
        }
      }}
      style={{
        background: palette.cardBg,
        // Longhands, not `border` + `borderLeft`: React applies the shorthand
        // and then clears the conflicting longhand, which zeroed the left
        // edge on every card without an accent colour (the whole Agents list).
        borderTop: `1px solid ${hovered ? palette.borderHover : palette.border}`,
        borderRight: `1px solid ${hovered ? palette.borderHover : palette.border}`,
        borderBottom: `1px solid ${hovered ? palette.borderHover : palette.border}`,
        borderLeft: accentColor
          ? `4px solid ${accentColor}`
          : `1px solid ${hovered ? palette.borderHover : palette.border}`,
        borderRadius: '12px',
        padding: '16px',
        cursor: onClick ? 'pointer' : 'default',
        transition: 'border-color 0.15s ease, box-shadow 0.15s ease',
        boxShadow: hovered && onClick ? '0 4px 16px rgba(0,0,0,0.08)' : 'none',
        display: 'flex',
        flexDirection: 'column',
        gap: '12px',
      }}
    >
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: '8px' }}>
        <div style={{ minWidth: 0 }}>
          <div
            style={{
              fontWeight: 600,
              fontSize: '15px',
              color: hovered && onClick ? '#ef4444' : palette.textPrimary,
              transition: 'color 0.15s ease',
              overflow: 'hidden',
              textOverflow: 'ellipsis',
              whiteSpace: 'nowrap',
            }}
            title={name}
          >
            {name}
          </div>
          {subtitle && (
            <div
              style={{
                fontSize: '13px',
                color: palette.textSecondary,
                marginTop: '2px',
                display: '-webkit-box',
                WebkitLineClamp: 2,
                WebkitBoxOrient: 'vertical',
                overflow: 'hidden',
              }}
            >
              {subtitle}
            </div>
          )}
        </div>
        {badge && <div style={{ flexShrink: 0 }}>{badge}</div>}
      </div>

      {stats.length > 0 && (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '6px' }}>
          {stats.map((stat) => (
            <div
              key={stat.label}
              title={stat.title}
              style={{ background: palette.tileBg, borderRadius: '8px', padding: '6px 8px', textAlign: 'center' }}
            >
              <div style={{ fontSize: '14px', fontWeight: 600, lineHeight: 1.2, color: toneColor(stat.tone) }}>
                {stat.value}
              </div>
              <div
                style={{
                  fontSize: '10px',
                  textTransform: 'uppercase',
                  letterSpacing: '0.04em',
                  color: palette.textMuted,
                  whiteSpace: 'nowrap',
                }}
              >
                {stat.label}
              </div>
            </div>
          ))}
        </div>
      )}

      {footer && (
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            gap: '8px',
            fontSize: '12px',
            color: palette.textMuted,
          }}
        >
          {footer}
        </div>
      )}

      {actions && (
        <div style={{ opacity: hovered ? 1 : 0, transition: 'opacity 0.15s ease' }}>{actions}</div>
      )}
    </div>
  );
}

/** Shared thresholds so a rate is coloured the same on every surface. */
export function rateTone(fraction) {
  if (fraction == null) return 'muted';
  if (fraction >= 0.85) return 'good';
  if (fraction >= 0.7) return 'warn';
  return 'bad';
}
