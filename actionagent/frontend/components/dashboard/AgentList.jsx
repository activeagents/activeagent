import React, { useEffect, useId, useMemo, useRef, useState } from 'react';
import AgentAvatar from '../AgentAvatar';
import { Button, Hint, MONO, Menu, PageHeader, TABLE, TONE } from './primitives';
import { fmtPasses, fmtPercent } from '../../utils/evalFormat.mjs';
import {
  activityTone, evalTone, fmtAgentCost, fmtDuration, fmtErrorRate, fmtLastSeen, fmtRuns,
} from '../../utils/agentStats.mjs';

// The Agents home: a titled table of every agent with the figures its
// API recorded over its window, one filter, one sort and one primary
// action. A row opens the agent; duplicating and deleting live on the agent
// page. The host still passes meta, onDuplicate, onDelete and onRefresh,
// which this view no longer reads.

// Mirrors Api::AgentsController::LIST_SORTS. Ordering is applied server-side,
// so these values are sent, not sorted on.
const SORTS = [
  { value: 'recent', label: 'Recently updated' },
  { value: 'popular', label: 'Most runs' },
  { value: 'longest', label: 'Longest average' },
  { value: 'cost', label: 'Highest cost' },
  { value: 'tokens', label: 'Most tokens' },
];

const COST_TITLE = 'Estimated from token counts at each model\'s published rates';

// The filter and the sort share one control recipe, so they read as a pair.
const CONTROL = {
  height: 36, boxSizing: 'border-box', padding: '0 12px',
  border: '1px solid var(--color-border-strong)', borderRadius: 8,
  background: 'var(--color-surface)', color: 'var(--color-text-primary)', font: 'inherit',
};

// Read by screen readers, not shown.
const VISUALLY_HIDDEN = {
  position: 'absolute', width: 1, height: 1, padding: 0, margin: -1, overflow: 'hidden',
  clip: 'rect(0 0 0 0)', whiteSpace: 'nowrap', border: 0,
};

const NUM = { fontFamily: MONO };
const MUTED = { color: 'var(--color-text-muted)' };

const DOT = {
  success: 'var(--color-success)',
  warning: 'var(--color-warning)',
  muted: 'var(--color-text-muted)',
};

const FILTER_FIELDS = ['name', 'description', 'provider', 'model', 'status'];

const matches = (agent, query) =>
  FILTER_FIELDS.some((field) => agent[field] != null && String(agent[field]).toLowerCase().includes(query));

// Which sources fed the run count, for its tooltip.
const runsTitle = (sources = []) => (sources.length
  ? `Counted from ${sources.map((s) => (s === 'platform' ? 'dashboard runs' : 'reported telemetry')).join(' + ')}`
  : undefined);

// The pass rate pooled over the headline runs of the agent's current
// evaluations; the fraction and what was left out ride in the title.
const evalTitle = (stats) => {
  if (stats.eval_samples_evaluated) {
    return `${fmtPasses(stats.eval_samples_passed, stats.eval_samples_evaluated)} passed over ${stats.eval_runs ?? 'the'} current evaluation${stats.eval_runs === 1 ? '' : 's'}`
      + (stats.eval_not_counted ? ` · ${stats.eval_not_counted} stale or archived not counted` : '');
  }
  if (stats.eval_not_counted) {
    return `${stats.eval_not_counted} evaluation${stats.eval_not_counted === 1 ? '' : 's'} stale or archived, none counted`;
  }
  return 'No evaluation counted yet';
};

// A key typed while a field, a select or an editable region has focus, or
// with ctrl, meta or alt held, is not a shortcut. Shift is not a modifier
// here: on some layouts '/' is typed with it.
const isTypingTarget = (element) =>
  !!element && (['INPUT', 'TEXTAREA', 'SELECT'].includes(element.tagName) || element.isContentEditable);

function EvalCell({ stats }) {
  const score = stats.eval_score;
  const tone = evalTone(score);
  return (
    <td style={TABLE.td} title={evalTitle(stats)}>
      <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8 }}>
        {score != null && (
          <span aria-hidden="true" style={{ width: 64, height: 4, borderRadius: 2, background: 'var(--color-muted)', overflow: 'hidden', flexShrink: 0 }}>
            <span style={{ display: 'block', height: '100%', borderRadius: 2, width: `${Math.round(Number(score) * 100)}%`, background: TONE[tone].strong }} />
          </span>
        )}
        <span style={TABLE.mono}>{fmtPercent(score)}</span>
      </span>
    </td>
  );
}

function AgentRow({ agent, onSelect }) {
  const stats = agent.stats || {};
  const errors = fmtErrorRate(stats.success_rate);
  const erring = parseFloat(errors) > 0;
  const updated = agent.updatedAt || agent.updated_at;
  const tag = agent.status && agent.status !== 'active' ? agent.status : null;

  const open = () => onSelect(agent);
  const onKeyDown = (event) => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      open();
    }
  };

  return (
    <tr
      className="aa-row"
      data-testid="agent-row"
      data-agent-name={agent.name}
      tabIndex={0}
      aria-label={`Open ${agent.name}`}
      onClick={open}
      onKeyDown={onKeyDown}
      style={{ cursor: 'pointer' }}
    >
      <td style={TABLE.td}>
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8 }}>
          <span aria-hidden="true" style={{ width: 8, height: 8, borderRadius: 4, flexShrink: 0, background: DOT[activityTone(stats)] }} />
          <span style={{ fontSize: 13, fontWeight: 500, color: 'var(--color-text-primary)' }}>{agent.name}</span>
          {tag && <span style={{ fontFamily: MONO, fontSize: 11, ...MUTED }}>{tag}</span>}
        </span>
      </td>
      <td style={{ ...TABLE.td, ...TABLE.mono, ...MUTED }} title={`${agent.provider} · ${agent.model}`}>{agent.model}</td>
      <td style={{ ...TABLE.td, ...NUM, ...TABLE.right }} title={runsTitle(stats.run_sources)}>{fmtRuns(stats.runs)}</td>
      <td style={{ ...TABLE.td, ...NUM, ...TABLE.right, ...(erring ? { color: 'var(--color-error-text)' } : {}) }}>{errors}</td>
      <td style={{ ...TABLE.td, ...NUM, ...TABLE.right }}>{fmtDuration(stats.avg_duration_ms)}</td>
      <EvalCell stats={stats} />
      <td style={{ ...TABLE.td, ...NUM, ...TABLE.right }} title={COST_TITLE}>{fmtAgentCost(stats.cost)}</td>
      <td style={{ ...TABLE.td, ...NUM, ...TABLE.right, ...MUTED }} title={updated ? `Updated ${fmtLastSeen(updated)}` : undefined}>
        {fmtLastSeen(stats.last_run_at)}
      </td>
    </tr>
  );
}

function EmptyState({ onNew, onBrowseTemplates }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', textAlign: 'center', gap: 12, padding: '56px 24px' }}>
      <AgentAvatar size={96} />
      <h2 style={{ margin: 0, fontSize: 20, fontWeight: 600, letterSpacing: '-0.01em', color: 'var(--color-text-primary)' }}>No agents yet</h2>
      <p style={{ margin: 0, color: 'var(--color-text-secondary)' }}>Create your first agent, or start from a template.</p>
      <div style={{ display: 'flex', alignItems: 'center', gap: 16, marginTop: 8 }}>
        <Button variant="primary" onClick={onNew}>New agent</Button>
        <button
          type="button"
          onClick={onBrowseTemplates}
          style={{ background: 'none', border: 0, padding: 0, font: 'inherit', fontWeight: 500, color: 'var(--color-accent-ui)', cursor: 'pointer' }}
        >
          Browse templates
        </button>
      </div>
    </div>
  );
}

export default function AgentList({
  agents,
  onSelect,
  onNew,
  onBrowseTemplates,
  sort = 'recent',
  onSortChange,
  isLoading = false,
}) {
  const [filter, setFilter] = useState('');
  const filterRef = useRef(null);
  const filterId = useId();

  const query = filter.trim().toLowerCase();
  const visible = useMemo(() => (query ? agents.filter((agent) => matches(agent, query)) : agents), [agents, query]);

  // The window every run count covers, as the API reports it.
  const windowDays = agents.find((agent) => agent.stats?.window_days)?.stats.window_days;

  // '/' focuses the filter from anywhere on the page.
  useEffect(() => {
    const onKeyDown = (event) => {
      if (event.key !== '/' || event.ctrlKey || event.metaKey || event.altKey) return;
      if (isTypingTarget(document.activeElement)) return;
      event.preventDefault();
      filterRef.current?.focus();
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, []);

  const actions = (
    <>
      <label htmlFor={filterId} style={VISUALLY_HIDDEN}>Filter agents</label>
      <input
        id={filterId}
        ref={filterRef}
        type="search"
        placeholder="Filter  /"
        value={filter}
        onChange={(event) => setFilter(event.target.value)}
        style={{ ...CONTROL, width: 220 }}
      />
      <select
        aria-label="Sort agents"
        value={sort}
        onChange={(event) => onSortChange?.(event.target.value)}
        style={CONTROL}
      >
        {SORTS.map((option) => (
          <option key={option.value} value={option.value}>{option.label}</option>
        ))}
      </select>
      {/* One primary action, split: the button creates from scratch, the
          menu beside it offers the template library. Both halves square
          the edge they share and a faint divider marks it. */}
      <div style={{ display: 'inline-flex', alignItems: 'stretch' }}>
        <Button
          variant="primary"
          onClick={onNew}
          testId="new-agent"
          style={{ borderTopRightRadius: 0, borderBottomRightRadius: 0 }}
        >
          New agent
        </Button>
        <Menu
          variant="primary"
          glyph="v"
          ariaLabel="More ways to create an agent"
          testId="new-agent-menu"
          items={[{ label: 'From a template', onClick: onBrowseTemplates, testId: 'new-agent-from-template' }]}
          triggerStyle={{ borderTopLeftRadius: 0, borderBottomLeftRadius: 0, borderLeftColor: 'rgba(255,255,255,0.35)' }}
        />
      </div>
    </>
  );

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      <PageHeader title="Agents" count={agents.length} actions={actions} testId="agents-header" />

      <div style={TABLE.frame} aria-busy={isLoading || undefined}>
        {agents.length === 0 ? (
          <EmptyState onNew={onNew} onBrowseTemplates={onBrowseTemplates} />
        ) : (
          <table style={{ ...TABLE.table, minWidth: 820 }}>
            <thead>
              <tr>
                <th scope="col" style={TABLE.th}>AGENT</th>
                <th scope="col" style={TABLE.th}>MODEL</th>
                <th scope="col" style={{ ...TABLE.th, ...TABLE.right }} title={windowDays ? `Over the last ${windowDays} days` : undefined}>RUNS</th>
                <th scope="col" style={{ ...TABLE.th, ...TABLE.right }}>ERRORS</th>
                <th scope="col" style={{ ...TABLE.th, ...TABLE.right }}>AVG</th>
                <th scope="col" style={TABLE.th}>EVAL</th>
                <th scope="col" style={{ ...TABLE.th, ...TABLE.right }}>COST</th>
                <th scope="col" style={{ ...TABLE.th, ...TABLE.right }}>LAST RUN</th>
              </tr>
            </thead>
            <tbody>
              {visible.length === 0 ? (
                <tr>
                  <td colSpan={8} style={{ ...TABLE.td, padding: '24px 14px', textAlign: 'center', ...MUTED }}>
                    No agents match “{filter.trim()}”.
                  </td>
                </tr>
              ) : (
                visible.map((agent) => <AgentRow key={agent.id ?? agent.name} agent={agent} onSelect={onSelect} />)
              )}
            </tbody>
          </table>
        )}
      </div>

      {agents.length > 0 && <Hint>Click a row to open it.</Hint>}
    </div>
  );
}
