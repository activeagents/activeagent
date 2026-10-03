import React, { useEffect, useState } from 'react';
import { Badge, Button, Card, Empty, MicroLabel, MONO } from './primitives';
import { timeAgo } from '../../utils/format';
import { dashboardPath, navigateTo } from '../../utils/dashboardPath';
import { sessionReplayPath } from '../../utils/dashboardRoutes.mjs';
import {
  EMPTY_FILTERS, SESSION_OUTCOMES, SESSION_SOURCES, filtersFromSearch, filtersSearch, hasFilters, sessionsPath,
} from '../../utils/sessionsQuery.mjs';

// The sessions a caller can replay (GET /api/sessions): dashboard
// conversations, evaluation replays and agent browser recordings, newest
// first. Filters run on the server and stay in the page's query string, so
// a filtered list can be linked to.

const SOURCE_BADGES = {
  dashboard: { tone: 'info', label: 'conversation' },
  evaluation: { tone: 'muted', label: 'evaluation' },
  agent: { tone: 'muted', label: 'browser' },
};

const OUTCOME_TONES = { failed: 'error', passed: 'success' };

const fieldStyle = {
  padding: '7px 10px', borderRadius: 8, fontSize: 13, fontFamily: 'inherit', boxSizing: 'border-box',
  background: 'var(--color-card)', border: '1px solid var(--color-border-strong)', color: 'var(--color-text-primary)',
};

async function fetchSessions(filters, before) {
  const response = await fetch(sessionsPath(filters, { before }));
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error || `Could not load sessions (HTTP ${response.status})`);
  return body;
}

// What a row says under its title: how much the session holds.
function sessionMeta(session) {
  const parts = [];
  if (session.kind === 'context') {
    parts.push(`${session.message_count} message${session.message_count === 1 ? '' : 's'}`);
    if (session.recording_count) parts.push('browser recorded');
  }
  if (session.kind === 'scenario_result') {
    if (session.evaluation?.name) parts.push(session.evaluation.name);
    if (session.model) parts.push(session.model);
  }
  if (session.kind === 'recording') {
    parts.push(`${session.event_count || 0} events`);
    if (session.action_count) parts.push(`${session.action_count} actions`);
  }
  return parts.join(' · ');
}

function FilterBar({ filters, onChange, agents, user }) {
  const set = (key) => (event) => onChange({ ...filters, [key]: event.target.value });
  return (
    <div data-testid="sessions-filters" style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
      <select aria-label="Agent" value={filters.agentId} onChange={set('agentId')} style={fieldStyle}>
        <option value="">Every agent</option>
        {agents.map((agent) => <option key={agent.id} value={String(agent.id)}>{agent.name}</option>)}
      </select>
      {user?.id != null && (
        <select aria-label="Run by" value={filters.user} onChange={set('user')} style={fieldStyle}>
          <option value="">Run by anyone</option>
          <option value="me">Run by me</option>
        </select>
      )}
      <select aria-label="Source" value={filters.source} onChange={set('source')} style={fieldStyle}>
        {SESSION_SOURCES.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
      </select>
      <select aria-label="Outcome" value={filters.outcome} onChange={set('outcome')} style={fieldStyle}>
        {SESSION_OUTCOMES.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
      </select>
      <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, color: 'var(--color-text-secondary)' }}>
        From
        <input type="date" aria-label="Active from" value={filters.from} max={filters.to || undefined} onChange={set('from')} style={fieldStyle} />
      </label>
      <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, color: 'var(--color-text-secondary)' }}>
        To
        <input type="date" aria-label="Active until" value={filters.to} min={filters.from || undefined} onChange={set('to')} style={fieldStyle} />
      </label>
      {hasFilters(filters) && (
        <Button variant="ghost" size="sm" testId="sessions-clear-filters" onClick={() => onChange(EMPTY_FILTERS)}>Clear filters</Button>
      )}
    </div>
  );
}

function SessionRow({ session }) {
  const path = sessionReplayPath(session.kind, session.id);
  const source = SOURCE_BADGES[session.source] || SOURCE_BADGES.agent;
  const meta = sessionMeta(session);
  return (
    <a
      href={dashboardPath(path)}
      data-testid="session-row"
      onClick={(event) => {
        if (event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0) return;
        event.preventDefault();
        navigateTo(path);
      }}
      style={{
        display: 'flex', alignItems: 'center', gap: 12, padding: '12px 16px', textDecoration: 'none',
        borderTop: '1px solid var(--color-border-light)', color: 'inherit',
      }}
    >
      <Badge tone={source.tone} style={{ width: 92, justifyContent: 'center' }}>{source.label}</Badge>
      <div style={{ minWidth: 0, flex: 1 }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, minWidth: 0 }}>
          <span style={{ fontFamily: MONO, fontSize: 13, fontWeight: 600, color: 'var(--color-text-primary)', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
            {session.title}
          </span>
          {session.agent && <span style={{ fontSize: 12, color: 'var(--color-text-secondary)', whiteSpace: 'nowrap' }}>{session.agent.name}</span>}
        </div>
        {session.preview && (
          <div style={{ fontSize: 12, color: 'var(--color-text-cell)', marginTop: 2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
            {session.preview}
          </div>
        )}
        {meta && <div style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)', marginTop: 2 }}>{meta}</div>}
      </div>
      {session.outcome && <Badge tone={OUTCOME_TONES[session.outcome] || 'muted'}>{session.outcome}</Badge>}
      <span title={session.last_activity_at} style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)', width: 96, textAlign: 'right', flexShrink: 0 }}>
        {timeAgo(session.last_activity_at)}
      </span>
      <span style={{ fontFamily: MONO, fontSize: 12, color: 'var(--color-info)', flexShrink: 0 }}>replay -&gt;</span>
    </a>
  );
}

export default function SessionsView({ agents = [], user = null }) {
  const [filters, setFilters] = useState(() => filtersFromSearch(window.location.search));
  const [page, setPage] = useState({ sessions: [], total: 0, nextBefore: null });
  const [status, setStatus] = useState('loading');
  const [error, setError] = useState(null);
  const [loadingMore, setLoadingMore] = useState(false);
  const [reload, setReload] = useState(0);

  useEffect(() => {
    window.history.replaceState(window.history.state, '', `${window.location.pathname}${filtersSearch(filters)}`);

    let cancelled = false;
    setStatus('loading');
    fetchSessions(filters, null)
      .then((body) => {
        if (cancelled) return;
        setPage({ sessions: body.sessions || [], total: body.total || 0, nextBefore: body.next_before || null });
        setStatus('ready');
      })
      .catch((failure) => {
        if (cancelled) return;
        setError(failure.message);
        setStatus('error');
      });
    return () => { cancelled = true; };
  }, [filters, reload]);

  const loadMore = async () => {
    setLoadingMore(true);
    try {
      const body = await fetchSessions(filters, page.nextBefore);
      setPage((current) => ({
        sessions: [...current.sessions, ...(body.sessions || [])],
        total: body.total ?? current.total,
        nextBefore: body.next_before || null,
      }));
    } catch (failure) {
      setError(failure.message);
    } finally {
      setLoadingMore(false);
    }
  };

  const filtered = hasFilters(filters);

  return (
    <div data-testid="sessions-view" style={{ display: 'flex', flexDirection: 'column', gap: 16, maxWidth: 1200 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
        <div>
          <h1 style={{ margin: 0, fontSize: 24, fontWeight: 700, letterSpacing: '-0.01em', color: 'var(--color-text-primary)' }}>Sessions</h1>
          <p style={{ margin: '4px 0 0', fontSize: 13, color: 'var(--color-text-secondary)' }}>
            Replay what an agent did: its messages, model calls and tool calls, and its browser when one was recorded.
          </p>
        </div>
        {status === 'ready' && (
          <MicroLabel>{page.total} session{page.total === 1 ? '' : 's'}</MicroLabel>
        )}
      </div>

      <FilterBar filters={filters} onChange={setFilters} agents={agents} user={user} />

      <Card padding={0} testId="sessions-list" style={{ overflow: 'hidden' }}>
        {status === 'loading' && <Empty>loading sessions…</Empty>}
        {status === 'error' && (
          <div style={{ padding: 20, display: 'flex', alignItems: 'center', gap: 12, color: 'var(--color-error-text)', fontSize: 13 }}>
            {error}
            <Button size="sm" onClick={() => setReload((count) => count + 1)}>Retry</Button>
          </div>
        )}
        {status === 'ready' && page.sessions.length === 0 && (
          <div data-testid="sessions-empty" style={{ padding: '32px 20px', textAlign: 'center' }}>
            {filtered ? (
              <>
                <div style={{ fontSize: 14, color: 'var(--color-text-primary)' }}>No sessions match these filters.</div>
                <Button variant="secondary" size="sm" style={{ marginTop: 12 }} onClick={() => setFilters(EMPTY_FILTERS)}>Clear filters</Button>
              </>
            ) : (
              <>
                <div style={{ fontSize: 14, color: 'var(--color-text-primary)' }}>No sessions yet.</div>
                <div style={{ fontSize: 13, color: 'var(--color-text-secondary)', marginTop: 6 }}>
                  Every conversation in an agent's Run workbench and every evaluation replay appears here, ready to replay.
                </div>
              </>
            )}
          </div>
        )}
        {status === 'ready' && page.sessions.map((session) => (
          <SessionRow key={`${session.kind}-${session.id}`} session={session} />
        ))}
      </Card>

      {status === 'ready' && page.nextBefore && (
        <div style={{ display: 'flex', justifyContent: 'center' }}>
          <Button size="sm" testId="sessions-load-more" onClick={loadMore} disabled={loadingMore}>
            {loadingMore ? 'Loading…' : 'Load more'}
          </Button>
        </div>
      )}
    </div>
  );
}
