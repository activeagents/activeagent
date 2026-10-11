import React from 'react';
import { MONO } from './primitives';

/**
 * AgentStatCard — the agent card of the Traces "agents" view
 * (/dashboard/traces). The Agents home lists its agents in a table.
 *
 * Every colour is a token from frontend/tokens.css, so the card follows the
 * theme without resolving a palette of its own. Numbers and their labels are
 * mono; the border strengthens on hover and nothing floats.
 *
 * Callers own their metrics, but they render through the same tiles.
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
  const [hovered, setHovered] = React.useState(false);

  const edge = `1px solid ${hovered ? 'var(--color-border-strong)' : 'var(--color-border)'}`;

  const toneColor = (tone) => {
    if (tone === 'good') return 'var(--color-success-text)';
    if (tone === 'warn') return 'var(--color-warning-text)';
    if (tone === 'bad') return 'var(--color-error-text)';
    if (tone === 'muted') return 'var(--color-text-muted)';
    return 'var(--color-text-primary)';
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
        background: 'var(--color-card)',
        // Longhands, not `border` + `borderLeft`: React applies the shorthand
        // and then clears the conflicting longhand, which zeroed the left
        // edge on every card without an accent colour.
        borderTop: edge,
        borderRight: edge,
        borderBottom: edge,
        borderLeft: accentColor ? `4px solid ${accentColor}` : edge,
        borderRadius: '12px',
        padding: '16px',
        cursor: onClick ? 'pointer' : 'default',
        transition: 'border-color 0.15s ease',
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
              fontSize: '13px',
              color: hovered && onClick ? 'var(--color-accent-ui)' : 'var(--color-text-primary)',
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
                color: 'var(--color-text-secondary)',
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
              style={{ background: 'var(--color-muted)', borderRadius: '8px', padding: '6px 8px', textAlign: 'center' }}
            >
              <div style={{ fontFamily: MONO, fontSize: '12px', fontWeight: 600, lineHeight: 1.2, color: toneColor(stat.tone) }}>
                {stat.value}
              </div>
              <div
                style={{
                  fontFamily: MONO,
                  fontSize: '11px',
                  textTransform: 'uppercase',
                  letterSpacing: '0.04em',
                  color: 'var(--color-text-muted)',
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
            color: 'var(--color-text-muted)',
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
