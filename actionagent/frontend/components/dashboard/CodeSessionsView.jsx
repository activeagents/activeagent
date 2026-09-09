import React, { useState, useEffect, useCallback, useMemo, useRef } from 'react';
import { dashboardPath, dashboardRelativePath } from '../../utils/dashboardPath';
import { navigateTo } from './ScenarioSuitePanel';
import { Badge, Button, Card, Chip, Empty, Glyph, MicroLabel, MonoLink, Panel, SegmentedControl, StatCard, MONO } from './primitives';
import { fmtCost, fmtK, fmtMs, timeAgo } from '../../utils/format';
import { plural } from './EvaluationRunPanels';
import CodeSessionBrief, { briefCounts } from './CodeSessionBrief';

// Code Sessions: hand one of the dashboard's agents, with the findings of
// its evaluations compiled into a brief, to a sandboxed coding agent. Three
// pages under /code — the list, the New form with a live brief preview, and
// a session's detail with its events and transcript — all routed here from
// the URL, so Dashboard only has to know that "/code" belongs to this view.

const POLL_MS = 3000;
const LIST_POLL_MS = 10000;
const PREVIEW_DEBOUNCE_MS = 500;

// Sessions the backend is still working on; these poll /events.
const ACTIVE_STATUSES = ['pending', 'provisioning', 'running'];

const STATUS_TONE = {
  pending: 'info', provisioning: 'info', ready: 'success', running: 'accent',
  completed: 'success', failed: 'error', expired: 'muted', stopped: 'muted',
};

const csrfToken = () => document.querySelector('meta[name="csrf-token"]')?.content;

const mono = (size = 11, color = 'var(--color-text-muted)', extra = {}) => ({ fontFamily: MONO, fontSize: size, color, ...extra });

const inputStyle = {
  padding: '8px 12px', borderRadius: 8, fontSize: 13, fontFamily: 'inherit', boxSizing: 'border-box', width: '100%',
  background: 'var(--color-card)', border: '1px solid var(--color-border-strong)', color: 'var(--color-text-primary)',
};
const monoInputStyle = { ...inputStyle, fontFamily: MONO, fontSize: 12 };

const sentence = (value) => String(value || '').replace(/_/g, ' ');

// One JSON request; a non-2xx response throws with the server's message so
// callers can show it verbatim.
async function api(path, { method = 'GET', body } = {}) {
  const response = await fetch(path, {
    method,
    headers: body ? { 'Content-Type': 'application/json', 'X-CSRF-Token': csrfToken() } : { 'X-CSRF-Token': csrfToken() },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (response.status === 204) return {};
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = (Array.isArray(data.errors) ? data.errors : [data.error]).filter(Boolean).join(', ');
    throw new Error(message || `Request failed (${response.status})`);
  }
  return data;
}

// /code → list; /code/new → form (with agent_id / evaluation_run_id from the
// query); /code/:id → detail.
function parseRoute() {
  const path = dashboardRelativePath();
  const segment = path.match(/^\/code(?:\/([^/?#]+))?/)?.[1];
  if (!segment) return { page: 'list' };
  if (segment === 'new') {
    const params = new URLSearchParams(window.location.search);
    return { page: 'new', agentId: params.get('agent_id') || '', evaluationRunId: params.get('evaluation_run_id') || '' };
  }
  return { page: 'detail', id: segment };
}

const isExpired = (session) => !!session?.expires_at && new Date(session.expires_at) < new Date();
const isActive = (session) => ACTIVE_STATUSES.includes(session?.status);
const canRun = (session) => ['ready', 'completed'].includes(session?.status) && !isExpired(session);

const clock = (iso) => {
  if (!iso) return '';
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? '' : date.toTimeString().slice(0, 8);
};

function StatusBadge({ status }) {
  return <Badge tone={STATUS_TONE[status] || 'muted'} testId="code-session-status">{status || 'unknown'}</Badge>;
}

function ErrorBox({ children }) {
  if (!children) return null;
  return (
    <div style={{ padding: '10px 12px', borderRadius: 8, fontSize: 13, background: 'var(--color-error-soft)', color: 'var(--color-error-text)', overflowWrap: 'anywhere' }}>
      {children}
    </div>
  );
}

function Field({ label, hint, children, style }) {
  return (
    <div style={{ minWidth: 0, ...style }}>
      <MicroLabel as="label" style={{ display: 'block', marginBottom: 6 }}>{label}</MicroLabel>
      {children}
      {hint && <div style={{ marginTop: 6, fontSize: 12, lineHeight: '17px', color: 'var(--color-text-muted)', textWrap: 'pretty' }}>{hint}</div>}
    </div>
  );
}

function PageHeader({ title, subtitle, meta, children, back }) {
  return (
    <div style={{ display: 'flex', alignItems: 'flex-start', gap: 16, flexWrap: 'wrap' }}>
      <div style={{ flex: 1, minWidth: 260, display: 'flex', flexDirection: 'column', gap: 6 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
          {back && (
            <Button size="sm" onClick={back}>
              <span style={{ fontFamily: MONO }}>{'<-'}</span> Code Sessions
            </Button>
          )}
          <h1 style={{ margin: 0, fontSize: 24, fontWeight: 700, letterSpacing: '-0.01em', color: 'var(--color-text-primary)' }}>{title}</h1>
          {meta}
        </div>
        {subtitle && <p style={{ margin: 0, fontSize: 14, color: 'var(--color-text-secondary)', textWrap: 'pretty' }}>{subtitle}</p>}
      </div>
      {children && <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>{children}</div>}
    </div>
  );
}

// ---------------------------------------------------------------------------
// List

const LIST_GRID = '110px minmax(120px, 1fr) minmax(120px, 1fr) minmax(160px, 1.4fr) 120px 60px 90px';

function SessionsList({ agents }) {
  const [sessions, setSessions] = useState([]);
  const [backend, setBackend] = useState(null);
  const [githubConfigured, setGithubConfigured] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const load = useCallback(async () => {
    try {
      const data = await api('/api/code_sessions');
      setSessions(data.sessions || []);
      setBackend(data.backend || null);
      setGithubConfigured(!!data.github_configured);
      setError(null);
    } catch (e) {
      setError(e.message);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  // Keep the list fresh while a sandbox is being provisioned or a run is in
  // flight; idle lists do not poll.
  const anyActive = sessions.some(isActive);
  useEffect(() => {
    if (!anyActive) return undefined;
    const interval = setInterval(load, LIST_POLL_MS);
    return () => clearInterval(interval);
  }, [anyActive, load]);

  const agentName = (session) => session.agent?.name || agents.find((a) => String(a.id) === String(session.agent?.id))?.name || '—';
  const features = backend?.features || {};
  const featureChips = [
    features.isolation,
    features.network,
    features.persistent === false ? 'ephemeral' : features.persistent ? 'persistent' : null,
    features.threat_monitoring ? 'threat monitoring' : null,
    features.self_hosted ? 'self-hosted' : null,
  ].filter(Boolean);

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
      <PageHeader title="Code Sessions" subtitle="Hand an agent and what its evaluations found to a sandboxed coding agent. The brief tells it what the agent needs and cannot do; the sandbox gives it a repository and nothing else.">
        <Button variant="primary" onClick={() => navigateTo('/code/new')} testId="new-code-session-button">New code session</Button>
      </PageHeader>

      <ErrorBox>{error && `Failed to load code sessions: ${error}`}</ErrorBox>

      {backend && (
        <Card padding={14} testId="code-sessions-backend">
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
            <MicroLabel>Backend</MicroLabel>
            <span style={{ ...mono(12, 'var(--color-text-primary)'), fontWeight: 600 }}>{backend.name}</span>
            <Badge tone={backend.healthy ? 'success' : 'error'}>{backend.healthy ? 'healthy' : 'unreachable'}</Badge>
            {featureChips.map((chip) => <Chip key={chip} square mono>{chip}</Chip>)}
            <span style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 8 }}>
              {githubConfigured ? (
                <Badge tone="success">GitHub token configured</Badge>
              ) : (
                <>
                  <Badge tone="muted">no GitHub token</Badge>
                  <MonoLink href={dashboardPath('/settings')} onClick={() => navigateTo('/settings')}>Provider API Keys</MonoLink>
                </>
              )}
            </span>
          </div>
        </Card>
      )}

      <Card padding={0} testId="code-sessions-table">
        <div style={{ overflowX: 'auto' }}>
          <div style={{ minWidth: 860 }}>
            <div style={{ display: 'grid', gridTemplateColumns: LIST_GRID, gap: 12, padding: '10px 16px', borderBottom: '1px solid var(--color-border-light)' }}>
              {['status', 'tool', 'agent', 'repository', 'brief', 'exit', 'created'].map((label) => (
                <MicroLabel key={label} size={10} color="var(--color-text-muted)" style={{ textAlign: label === 'exit' ? 'right' : 'left' }}>{label}</MicroLabel>
              ))}
            </div>
            {loading && sessions.length === 0 ? (
              <Empty>[ ] loading…</Empty>
            ) : sessions.length === 0 ? (
              <Empty style={{ padding: '28px 12px' }}>[ ] no code sessions yet — start one from an evaluation's "What to fix" panel, or with New code session</Empty>
            ) : sessions.map((session) => (
              <a
                key={session.id}
                href={dashboardPath(`/code/${session.id}`)}
                onClick={(event) => { event.preventDefault(); navigateTo(`/code/${session.id}`); }}
                data-testid="code-session-row"
                style={{ display: 'grid', gridTemplateColumns: LIST_GRID, gap: 12, padding: '10px 16px', alignItems: 'center', borderBottom: '1px solid var(--color-border-light)', textDecoration: 'none', color: 'inherit' }}
              >
                <span><StatusBadge status={session.status} /></span>
                <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--color-text-primary)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{session.tool_name || session.tool}</span>
                <span style={{ fontSize: 13, color: 'var(--color-text-cell)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{agentName(session)}</span>
                <span style={{ ...mono(11, 'var(--color-text-cell)'), overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }} title={session.repository || ''}>
                  {session.repository || 'scratch workspace'}{session.branch ? <span style={{ color: 'var(--color-text-muted)' }}>{`@${session.branch}`}</span> : null}
                </span>
                <span style={mono(11)}>{`${session.needs_count ?? 0} needs · ${session.limitations_count ?? 0} limits`}</span>
                <span style={{ ...mono(11, session.exit_code == null ? 'var(--color-text-muted)' : session.exit_code === 0 ? 'var(--color-success-text)' : 'var(--color-error-text)'), textAlign: 'right', fontWeight: 600 }}>{session.exit_code ?? '—'}</span>
                <span style={mono(11)}>{timeAgo(session.created_at)}</span>
              </a>
            ))}
          </div>
        </div>
      </Card>
    </div>
  );
}

// ---------------------------------------------------------------------------
// New

// The default task lives in the brief's markdown under "## Task"; the JSON
// shape has no task field of its own. Any explicit field the API might add
// later wins over the parse.
function defaultTaskFrom(data) {
  const explicit = data?.task || data?.default_task || data?.brief?.task;
  if (explicit) return String(explicit);
  const markdown = String(data?.markdown || '');
  const start = markdown.search(/^## Task[ \t]*$/m);
  if (start < 0) return '';
  const body = markdown.slice(markdown.indexOf('\n', start) + 1);
  const next = body.search(/^## /m);
  return (next < 0 ? body : body.slice(0, next)).trim();
}

// timeAgo reads a future timestamp as "just now"; expiry needs the other
// direction.
const timeUntil = (iso) => {
  if (!iso) return '';
  const mins = Math.ceil((new Date(iso).getTime() - Date.now()) / 60000);
  if (mins <= 0) return 'now';
  if (mins < 60) return `in ${mins} min`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `in ${hours} hour${hours === 1 ? '' : 's'}`;
  const days = Math.floor(hours / 24);
  return `in ${days} day${days === 1 ? '' : 's'}`;
};

const runLabel = (run) => {
  const passed = run.samples_passed ?? null;
  const total = run.samples_evaluated ?? null;
  const score = passed != null && total ? ` · ${passed}/${total} passed` : '';
  return `run ${run.id} · ${run.status}${score} · ${timeAgo(run.completed_at || run.created_at)}`;
};

function NewSession({ agents: initialAgents, agentId: seedAgentId, evaluationRunId: seedRunId }) {
  const [agents, setAgents] = useState(initialAgents || []);
  const [catalog, setCatalog] = useState(null);
  const [catalogError, setCatalogError] = useState(null);
  const [evaluations, setEvaluations] = useState([]);
  const [runs, setRuns] = useState([]);
  const [form, setForm] = useState({
    agent_id: seedAgentId || '', evaluation_id: '', evaluation_run_id: seedRunId || '',
    tool: '', backend: '', repository: '', branch: '', github_access: 'none', network_mode: 'restricted',
    model: '', task: '', run: true,
  });
  const [taskDirty, setTaskDirty] = useState(false);
  const [preview, setPreview] = useState(null);
  const [previewState, setPreviewState] = useState('idle'); // idle | loading | ready | error
  const [previewError, setPreviewError] = useState(null);
  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState(null);
  // The run id seeded from the URL is honoured once, when its evaluation's
  // runs first load; after that the selects own it.
  const seededRun = useRef(seedRunId || '');

  const update = (patch) => setForm((current) => ({ ...current, ...patch }));

  useEffect(() => {
    if (agents.length > 0) return;
    fetch('/api/agents')
      .then((r) => (r.ok ? r.json() : { agents: [] }))
      .then((data) => setAgents(data.agents || []))
      .catch(() => setAgents([]));
  }, [agents.length]);

  useEffect(() => {
    api('/api/code_sessions/catalog')
      .then((data) => {
        setCatalog(data);
        const tools = data.tools || [];
        const first = tools.find((t) => t.key === 'claude_code' && t.supported) || tools.find((t) => t.supported) || tools[0];
        setForm((current) => ({
          ...current,
          tool: current.tool || first?.key || '',
          backend: current.backend || data.default_backend || '',
          network_mode: (data.network_modes || []).includes(current.network_mode) ? current.network_mode : (data.network_modes?.[0] || current.network_mode),
        }));
      })
      .catch((e) => setCatalogError(e.message));
  }, []);

  // Agent → its scenario suites → the suite (and run) to seed the brief from.
  useEffect(() => {
    if (!form.agent_id) { setEvaluations([]); setRuns([]); return undefined; }
    let cancelled = false;
    (async () => {
      try {
        const data = await api(`/api/evaluations?agent_id=${encodeURIComponent(form.agent_id)}`);
        if (cancelled) return;
        const suites = (data.evaluations || []).filter((e) => e.scenario_suite);
        setEvaluations(suites);
        const seed = seededRun.current;
        let chosen = seed ? suites.find((e) => String(e.latest_run?.id) === String(seed)) : null;
        // The seeded run may be older than the suite's latest: look through
        // each suite's runs (bounded by the list the API already capped).
        if (seed && !chosen) {
          for (const suite of suites) {
            const detail = await api(`/api/evaluations/${suite.id}`).catch(() => null);
            if (cancelled) return;
            if ((detail?.runs || []).some((run) => String(run.id) === String(seed))) { chosen = suite; break; }
          }
        }
        if (!chosen) chosen = suites.find((e) => e.latest_run?.status === 'complete') || suites[0] || null;
        setForm((current) => ({ ...current, evaluation_id: chosen ? String(chosen.id) : '', evaluation_run_id: chosen ? current.evaluation_run_id : '' }));
        if (!chosen) seededRun.current = '';
      } catch {
        if (!cancelled) { setEvaluations([]); setRuns([]); }
      }
    })();
    return () => { cancelled = true; };
  }, [form.agent_id]);

  useEffect(() => {
    if (!form.evaluation_id) { setRuns([]); return undefined; }
    let cancelled = false;
    api(`/api/evaluations/${form.evaluation_id}`)
      .then((data) => {
        if (cancelled) return;
        const list = data.runs || [];
        setRuns(list);
        const seed = seededRun.current;
        seededRun.current = '';
        const seeded = seed && list.find((run) => String(run.id) === String(seed));
        const newest = list.find((run) => run.status === 'complete');
        setForm((current) => ({ ...current, evaluation_run_id: seeded ? String(seeded.id) : newest ? String(newest.id) : '' }));
      })
      .catch(() => { if (!cancelled) setRuns([]); });
    return () => { cancelled = true; };
  }, [form.evaluation_id]);

  // Live brief preview, debounced on exactly the inputs the brief depends
  // on. Whether the user has edited the task is read through a ref so a
  // keystroke in the textarea does not recompile the brief.
  const taskDirtyRef = useRef(false);
  taskDirtyRef.current = taskDirty;
  const { agent_id: agentId, evaluation_run_id: evaluationRunId, tool: toolKey, network_mode: networkMode, github_access: githubAccess, repository } = form;
  useEffect(() => {
    if (!agentId || !toolKey) { setPreview(null); setPreviewState('idle'); return undefined; }
    setPreviewState('loading');
    let cancelled = false;
    const timer = setTimeout(async () => {
      try {
        const data = await api('/api/code_sessions/preview_brief', {
          method: 'POST',
          body: {
            agent_id: agentId,
            evaluation_run_id: evaluationRunId || undefined,
            tool: toolKey,
            network_mode: networkMode,
            github_access: githubAccess,
            repository: repository.trim() || undefined,
          },
        });
        if (cancelled) return;
        setPreview(data);
        setPreviewState('ready');
        setPreviewError(null);
        const task = defaultTaskFrom(data);
        if (task) setForm((current) => (taskDirtyRef.current && current.task ? current : { ...current, task }));
      } catch (e) {
        if (cancelled) return;
        setPreviewState('error');
        setPreviewError(e.message);
      }
    }, PREVIEW_DEBOUNCE_MS);
    return () => { cancelled = true; clearTimeout(timer); };
  }, [agentId, evaluationRunId, toolKey, networkMode, githubAccess, repository]);

  const tools = catalog?.tools || [];
  const selectedTool = tools.find((t) => t.key === form.tool) || null;
  const backends = catalog?.backends || [];
  const githubConfigured = !!catalog?.github_configured;
  const networkModes = (catalog?.network_modes || ['restricted', 'allowlist', 'open']).map((value) => ({ value, label: sentence(value) }));
  const accessModes = (catalog?.github_access_modes || ['none', 'read', 'write']).map((value) => ({ value, label: sentence(value) }));
  const limits = catalog?.limits || {};
  const credentialNames = (selectedTool?.credentials || []).map((group) => (Array.isArray(group) ? group.join(' | ') : group));

  const submit = async (event) => {
    event.preventDefault();
    if (submitting) return;
    setSubmitting(true);
    setSubmitError(null);
    try {
      const data = await api('/api/code_sessions', {
        method: 'POST',
        body: {
          code_session: {
            agent_id: form.agent_id,
            evaluation_run_id: form.evaluation_run_id || null,
            tool: form.tool,
            backend: form.backend || undefined,
            repository: form.repository.trim() || null,
            branch: form.branch.trim() || null,
            github_access: form.github_access,
            network_mode: form.network_mode,
            model: form.model.trim() || null,
            task: form.task,
            run: form.run,
          },
        },
      });
      navigateTo(`/code/${data.session.id}`);
    } catch (e) {
      setSubmitError(e.message);
      setSubmitting(false);
    }
  };

  const counts = briefCounts(preview?.brief);
  const defaultTask = defaultTaskFrom(preview);

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
      <PageHeader title="New code session" back={() => navigateTo('/code')} subtitle="Pick the agent and the evaluation run whose findings become the brief, then the coding agent and the sandbox it gets." />

      <ErrorBox>{catalogError && `Failed to load the coding agent catalog: ${catalogError}`}</ErrorBox>

      <div style={{ display: 'grid', gridTemplateColumns: 'minmax(360px, 2fr) minmax(0, 3fr)', gap: 20, alignItems: 'start' }}>
        <Card testId="new-code-session-form">
          <form onSubmit={submit} style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
            <Field label="Agent">
              <select
                required
                value={form.agent_id}
                onChange={(e) => { seededRun.current = ''; update({ agent_id: e.target.value, evaluation_id: '', evaluation_run_id: '' }); }}
                style={inputStyle}
                data-testid="code-session-agent"
              >
                <option value="">Select agent…</option>
                {agents.map((agent) => (
                  <option key={agent.id} value={agent.id} disabled={agent.status === 'observed'}>
                    {agent.name}{agent.status === 'observed' ? ' (observed, read-only)' : ''}
                  </option>
                ))}
              </select>
            </Field>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
              <Field label="Evaluation" hint={form.agent_id && evaluations.length === 0 ? 'No scenario suites for this agent; the brief will carry only sandbox and metrics.' : null}>
                <select
                  value={form.evaluation_id}
                  disabled={!form.agent_id || evaluations.length === 0}
                  onChange={(e) => { seededRun.current = ''; update({ evaluation_id: e.target.value, evaluation_run_id: '' }); }}
                  style={inputStyle}
                >
                  <option value="">None</option>
                  {evaluations.map((evaluation) => (
                    <option key={evaluation.id} value={evaluation.id}>{evaluation.name}</option>
                  ))}
                </select>
              </Field>
              <Field label="Run">
                <select
                  value={form.evaluation_run_id}
                  disabled={!form.evaluation_id}
                  onChange={(e) => update({ evaluation_run_id: e.target.value })}
                  style={monoInputStyle}
                  data-testid="code-session-run"
                >
                  <option value="">latest complete (automatic)</option>
                  {runs.map((run) => (
                    <option key={run.id} value={run.id} disabled={run.status !== 'complete'}>{runLabel(run)}</option>
                  ))}
                </select>
              </Field>
            </div>

            <Field
              label="Coding agent"
              hint={selectedTool && (
                <span style={{ display: 'flex', flexWrap: 'wrap', gap: '2px 10px', ...mono(11) }}>
                  {selectedTool.vendor && <span>{selectedTool.vendor}</span>}
                  <span>{selectedTool.headless ? 'headless run' : 'headless is experimental; attach to drive it'}</span>
                  {credentialNames.length > 0 && <span>{`needs ${credentialNames.join(', ')}`}</span>}
                  {selectedTool.docs_url && <a href={selectedTool.docs_url} target="_blank" rel="noreferrer" style={{ color: 'var(--color-info)', textDecoration: 'none' }}>{'docs ->'}</a>}
                </span>
              )}
            >
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }} data-testid="code-session-tools">
                {tools.map((tool) => {
                  const supported = tool.supported !== false;
                  const reason = tool.unsupported_reason || tool.reason || `not supported by the ${form.backend || catalog?.default_backend || 'current'} backend`;
                  return (
                    <Chip
                      key={tool.key}
                      selected={form.tool === tool.key}
                      onClick={supported ? () => update({ tool: tool.key }) : undefined}
                      title={supported ? (tool.experimental ? 'Experimental: the headless path is not confirmed for this tool' : tool.name) : reason}
                      style={supported ? undefined : { opacity: 0.45, cursor: 'not-allowed' }}
                    >
                      {tool.name}{tool.experimental ? <span style={{ ...mono(10), marginLeft: 6 }}>exp</span> : null}
                    </Chip>
                  );
                })}
                {tools.length === 0 && !catalogError && <span style={mono(11)}>loading catalog…</span>}
              </div>
            </Field>

            <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 12 }}>
              <Field label="Repository" hint="owner/repo or a GitHub URL. Blank gives the coding agent an empty workspace.">
                <input type="text" value={form.repository} onChange={(e) => update({ repository: e.target.value })} placeholder="owner/repo" style={monoInputStyle} data-testid="code-session-repository" />
              </Field>
              <Field label="Branch">
                <input type="text" value={form.branch} onChange={(e) => update({ branch: e.target.value })} placeholder="default" style={monoInputStyle} />
              </Field>
            </div>

            <Field
              label="GitHub access"
              hint={githubConfigured
                ? 'Read clones with the token; write also lets the coding agent push a branch and open a pull request. The token is read from a file inside the sandbox, never printed.'
                : (
                  <span>
                    Add a GitHub token under Settings <span style={{ fontFamily: MONO }}>{'->'}</span> Provider API Keys to clone private repositories or push.{' '}
                    <MonoLink href={dashboardPath('/settings')} onClick={() => navigateTo('/settings')}>Settings</MonoLink>
                  </span>
                )}
            >
              <div style={{ opacity: githubConfigured ? 1 : 0.5, pointerEvents: githubConfigured ? 'auto' : 'none' }} aria-disabled={!githubConfigured} data-testid="code-session-github-access">
                <SegmentedControl options={accessModes} value={form.github_access} onChange={(value) => update({ github_access: value })} />
              </div>
            </Field>

            <Field label="Network" hint="Restricted allows only the hosts the profile lists; open lets package installs reach anything.">
              <SegmentedControl options={networkModes} value={form.network_mode} onChange={(value) => update({ network_mode: value })} />
            </Field>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
              <Field label="Model" hint="Optional override for the coding agent's own model.">
                <input type="text" value={form.model} onChange={(e) => update({ model: e.target.value })} placeholder="tool default" style={monoInputStyle} />
              </Field>
              <Field label="Backend">
                {backends.length > 1 ? (
                  <select value={form.backend} onChange={(e) => update({ backend: e.target.value })} style={monoInputStyle}>
                    {backends.map((name) => <option key={name} value={name}>{name}</option>)}
                  </select>
                ) : (
                  <div style={{ ...monoInputStyle, color: 'var(--color-text-cell)', background: 'var(--color-muted)', border: '1px solid var(--color-border-light)' }}>{form.backend || catalog?.default_backend || '—'}</div>
                )}
              </Field>
            </div>

            <Field
              label="Task"
              hint={(
                <span style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
                  <span>The prompt the coding agent receives; the brief travels alongside it as /brief/BRIEF.md.</span>
                  {taskDirty && defaultTask && (
                    <MonoLink onClick={() => { update({ task: defaultTask }); setTaskDirty(false); }}>reset to default</MonoLink>
                  )}
                </span>
              )}
            >
              <textarea
                value={form.task}
                onChange={(e) => { setTaskDirty(true); update({ task: e.target.value }); }}
                rows={9}
                maxLength={20000}
                placeholder={previewState === 'loading' ? 'Compiling the default task…' : 'Work in /workspace/repo…'}
                style={{ ...inputStyle, lineHeight: '19px', resize: 'vertical' }}
                data-testid="code-session-task"
              />
            </Field>

            <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, color: 'var(--color-text-cell)', cursor: 'pointer' }}>
              <input type="checkbox" checked={form.run} onChange={(e) => update({ run: e.target.checked })} />
              Start the run as soon as the sandbox is ready
            </label>

            <ErrorBox>{submitError}</ErrorBox>

            <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap', paddingTop: 4, borderTop: '1px solid var(--color-border-light)' }}>
              <Button type="submit" variant="primary" disabled={submitting || !form.agent_id || !form.tool} testId="create-code-session">
                {submitting ? 'Creating…' : 'Create session'}
              </Button>
              <Button onClick={() => navigateTo('/code')}>Cancel</Button>
              {limits.session_duration_minutes && (
                <span style={{ marginLeft: 'auto', ...mono(11) }}>{`expires after ${limits.session_duration_minutes} min · ${limits.max_sessions_per_owner ?? '—'} active max`}</span>
              )}
            </div>
          </form>
        </Card>

        <Card padding={16} testId="code-session-preview">
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap', marginBottom: 12 }}>
            <MicroLabel>Brief preview</MicroLabel>
            {preview?.brief && (
              <>
                <Badge tone={counts.needs ? 'error' : 'success'}>{plural(counts.needs, 'need')}</Badge>
                <Badge tone={counts.limitations ? 'warning' : 'success'}>{plural(counts.limitations, 'limitation')}</Badge>
                <Badge tone="muted">{`${counts.failing} failing`}</Badge>
              </>
            )}
            <span style={{ marginLeft: 'auto', ...mono(11) }}>
              {previewState === 'loading' ? 'compiling…' : previewState === 'ready' && preview?.brief?.generated_at ? `compiled ${timeAgo(preview.brief.generated_at)}` : ''}
            </span>
          </div>
          {previewState === 'error' && <ErrorBox>{`Preview failed: ${previewError}`}</ErrorBox>}
          {!form.agent_id ? (
            <Empty style={{ padding: '40px 12px' }}>[ ] pick an agent to compile its brief</Empty>
          ) : preview?.brief ? (
            <CodeSessionBrief brief={preview.brief} compact onNavigate={navigateTo} />
          ) : previewState === 'loading' ? (
            <Empty style={{ padding: '40px 12px' }}>[ ] compiling…</Empty>
          ) : null}
        </Card>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Detail

const eventGlyph = (event) => {
  const status = String(event.status || 'done');
  if (['error', 'failed'].includes(status)) return 'fault';
  if (['pending', 'running', 'started'].includes(status)) return 'info';
  return 'pass';
};

function EventsPanel({ events = [] }) {
  return (
    <Panel title="Events" meta={plural(events.length, 'event')} testId="code-session-events" bodyStyle={{ maxHeight: 480, overflowY: 'auto' }}>
      {events.length === 0 ? (
        <Empty>[ ] nothing yet</Empty>
      ) : events.map((event, index) => (
        <div key={event.eid || `${event.at}-${index}`} style={{ display: 'grid', gridTemplateColumns: '64px 24px minmax(0, 1fr)', gap: 8, padding: '8px 12px', borderBottom: index === events.length - 1 ? 'none' : '1px solid var(--color-border-light)', alignItems: 'start' }}>
          <span style={mono(11)}>{clock(event.at)}</span>
          <Glyph kind={eventGlyph(event)} />
          <div style={{ minWidth: 0 }}>
            <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, flexWrap: 'wrap' }}>
              <span style={{ fontSize: 13, color: 'var(--color-text-primary)' }}>{event.label}</span>
              {event.kind && <span style={mono(10)}>{event.kind}</span>}
            </div>
            {event.detail && <pre style={{ margin: '4px 0 0', ...mono(11, 'var(--color-text-secondary)'), whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{event.detail}</pre>}
          </div>
        </div>
      ))}
    </Panel>
  );
}

function TranscriptPanel({ transcript, running }) {
  return (
    <Panel title="Transcript" meta={transcript ? `${fmtK(transcript.length)} chars` : null} testId="code-session-transcript">
      {transcript ? (
        <pre style={{ margin: 0, padding: 12, maxHeight: 480, overflow: 'auto', ...mono(11, 'var(--color-text-cell)'), lineHeight: '17px', whiteSpace: 'pre-wrap', overflowWrap: 'anywhere', background: 'var(--color-muted)' }}>{transcript}</pre>
      ) : (
        <Empty>{running ? '[ ] running — the transcript lands when the run finishes' : '[ ] no run yet'}</Empty>
      )}
    </Panel>
  );
}

function SessionDetail({ id }) {
  const [session, setSession] = useState(null);
  const [loadError, setLoadError] = useState(null);
  const [actionError, setActionError] = useState(null);
  const [acting, setActing] = useState(null); // run | stop | delete
  const [copied, setCopied] = useState(false);
  const [now, setNow] = useState(() => Date.now());

  const load = useCallback(async () => {
    try {
      const data = await api(`/api/code_sessions/${id}`);
      setSession(data.session);
      setLoadError(null);
    } catch (e) {
      setLoadError(e.message);
    }
  }, [id]);

  useEffect(() => { load(); }, [load]);

  // Poll the light /events endpoint while the backend works; when it settles,
  // one full reload picks up tokens, cost and completion time.
  const active = isActive(session);
  useEffect(() => {
    if (!active) return undefined;
    const interval = setInterval(async () => {
      try {
        const data = await api(`/api/code_sessions/${id}/events`);
        setSession((current) => (current ? { ...current, status: data.status, events: data.events || current.events, transcript: data.transcript ?? current.transcript, exit_code: data.exit_code ?? current.exit_code } : current));
        if (!ACTIVE_STATUSES.includes(data.status)) { clearInterval(interval); load(); }
      } catch {
        // A missed poll is retried on the next tick.
      }
    }, POLL_MS);
    return () => clearInterval(interval);
  }, [active, id, load]);

  // A live runtime while the run is going.
  useEffect(() => {
    if (session?.status !== 'running') return undefined;
    const interval = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(interval);
  }, [session?.status]);

  const act = async (verb) => {
    if (acting) return;
    setActing(verb);
    setActionError(null);
    try {
      if (verb === 'delete') {
        if (!window.confirm('Delete this code session? Its sandbox is terminated and the transcript is gone.')) { setActing(null); return; }
        await api(`/api/code_sessions/${id}`, { method: 'DELETE' });
        navigateTo('/code');
        return;
      }
      const data = await api(`/api/code_sessions/${id}/${verb}`, { method: 'POST', body: {} });
      if (data.session) setSession((current) => ({ ...current, ...data.session }));
      else load();
    } catch (e) {
      setActionError(e.message);
    } finally {
      setActing(null);
    }
  };

  const copyAttach = async () => {
    if (!session?.attach_command) return;
    try {
      await navigator.clipboard.writeText(session.attach_command);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      // Clipboard unavailable (insecure context); the command is shown below for manual copy.
      setCopied(false);
    }
  };

  if (loadError) {
    return (
      <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
        <PageHeader title="Code session" back={() => navigateTo('/code')} />
        <ErrorBox>{`Failed to load code session ${id}: ${loadError}`}</ErrorBox>
      </div>
    );
  }
  if (!session) return <Empty style={{ padding: 40 }}>[ ] loading…</Empty>;

  const tokens = (session.input_tokens || 0) + (session.output_tokens || 0);
  const startedAt = session.started_at ? new Date(session.started_at).getTime() : null;
  const endedAt = session.completed_at ? new Date(session.completed_at).getTime() : (session.status === 'running' ? now : null);
  const runtimeMs = startedAt && endedAt ? Math.max(endedAt - startedAt, 0) : null;
  const expired = isExpired(session);
  const exitColor = session.exit_code == null ? undefined : session.exit_code === 0 ? 'var(--color-success)' : 'var(--color-error)';
  const counts = briefCounts(session.brief);

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }} data-testid="code-session-detail">
      <PageHeader
        title={session.tool_name || session.tool}
        back={() => navigateTo('/code')}
        meta={<StatusBadge status={session.status} />}
        subtitle={(
          <span style={{ display: 'flex', flexWrap: 'wrap', gap: '4px 16px', alignItems: 'baseline' }}>
            {session.agent && (
              <MonoLink size={12} href={dashboardPath(`/agents/${session.agent.id}/edit`)} onClick={() => navigateTo(`/agents/${session.agent.id}/edit`)}>{`@ ${session.agent.name}`}</MonoLink>
            )}
            <span style={mono(12, 'var(--color-text-cell)')}>{session.repository ? `${session.repository}${session.branch ? `@${session.branch}` : ''}` : 'scratch workspace'}</span>
            <span style={mono(11)}>{session.session_id}</span>
            <span style={mono(11)}>{`${session.backend} · ${session.network_mode} · github ${session.github_access}`}</span>
            {session.evaluation_run_id && <span style={mono(11)}>{`seeded by run ${session.evaluation_run_id}`}</span>}
          </span>
        )}
      >
        <Button variant="primary" size="sm" disabled={!canRun(session) || !!acting} onClick={() => act('run')} testId="code-session-run" title={canRun(session) ? 'Run the coding agent against the task' : 'Runs once the sandbox is ready'}>
          {acting === 'run' ? 'Starting…' : session.status === 'completed' ? 'Run again' : 'Run'}
        </Button>
        <Button size="sm" disabled={!active || !!acting} onClick={() => act('stop')} testId="code-session-stop">{acting === 'stop' ? 'Stopping…' : 'Stop'}</Button>
        <Button size="sm" disabled={!session.attach_command} onClick={copyAttach} title={session.attach_command ? 'Copy the command that attaches a terminal to this sandbox' : 'This backend has no attach command'} testId="code-session-attach">
          {copied ? 'Copied' : 'Attach'}
        </Button>
        <Button variant="danger" size="sm" disabled={!!acting} onClick={() => act('delete')} testId="code-session-delete">{acting === 'delete' ? 'Deleting…' : 'Delete'}</Button>
      </PageHeader>

      {session.attach_command && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap', ...mono(11) }}>
          <span>{copied ? 'copied — run it in a terminal on the sandbox host:' : 'attach from a terminal on the sandbox host:'}</span>
          <code style={{ ...mono(11, 'var(--color-text-cell)'), padding: '2px 8px', borderRadius: 6, background: 'var(--color-muted)', overflowWrap: 'anywhere' }}>{session.attach_command}</code>
        </div>
      )}

      <ErrorBox>{actionError}</ErrorBox>
      <ErrorBox>{session.error_message}</ErrorBox>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: 12 }}>
        <StatCard label="Exit code" value={session.exit_code ?? '—'} valueColor={exitColor} sub={session.completed_at ? `finished ${timeAgo(session.completed_at)}` : session.status === 'running' ? 'running' : 'no run yet'} testId="stat-exit-code" />
        <StatCard label="Tokens" value={tokens ? fmtK(tokens) : '—'} sub={tokens ? `${fmtK(session.input_tokens || 0)} in · ${fmtK(session.output_tokens || 0)} out` : 'reported by the tool when available'} testId="stat-tokens" />
        <StatCard label="Cost" value={session.cost == null ? '—' : fmtCost(session.cost, 2)} sub={session.model ? session.model : 'tool default model'} testId="stat-cost" />
        <StatCard
          label="Runtime"
          value={runtimeMs == null ? '—' : fmtMs(runtimeMs)}
          sub={expired ? 'sandbox expired' : session.expires_at ? `expires ${timeUntil(session.expires_at)}` : null}
          testId="stat-runtime"
        />
      </div>

      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, flexWrap: 'wrap' }}>
        <MicroLabel>Brief</MicroLabel>
        <span style={mono(11)}>{`${plural(counts.needs, 'need')} · ${plural(counts.limitations, 'limitation')} · ${counts.failing} failing`}</span>
      </div>
      {session.brief && Object.keys(session.brief).length > 0 ? (
        <CodeSessionBrief brief={session.brief} onNavigate={navigateTo} />
      ) : (
        <Empty style={{ border: '1px solid var(--color-border-light)', borderRadius: 10 }}>[ ] no brief was compiled for this session</Empty>
      )}

      <Panel title="Task" testId="code-session-task">
        <pre style={{ margin: 0, padding: 12, maxHeight: 220, overflow: 'auto', fontFamily: 'inherit', fontSize: 13, lineHeight: '19px', color: 'var(--color-text-cell)', whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{session.task || '—'}</pre>
      </Panel>

      <div style={{ display: 'grid', gridTemplateColumns: 'minmax(280px, 1fr) minmax(0, 2fr)', gap: 16, alignItems: 'start' }}>
        <EventsPanel events={session.events || []} />
        <TranscriptPanel transcript={session.transcript} running={session.status === 'running'} />
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------

export default function CodeSessionsView({ agents = [] }) {
  const [route, setRoute] = useState(parseRoute);

  // The URL is the state: back/forward, the shared navigateTo helper (which
  // dispatches dashboard:navigate), and Dashboard's sidebar push all land
  // here.
  useEffect(() => {
    const apply = () => setRoute(parseRoute());
    window.addEventListener('popstate', apply);
    window.addEventListener('dashboard:navigate', apply);
    return () => {
      window.removeEventListener('popstate', apply);
      window.removeEventListener('dashboard:navigate', apply);
    };
  }, []);

  const routeKey = useMemo(() => `${route.page}:${route.id || ''}:${route.agentId || ''}:${route.evaluationRunId || ''}`, [route]);

  if (route.page === 'new') {
    return <NewSession key={routeKey} agents={agents} agentId={route.agentId} evaluationRunId={route.evaluationRunId} />;
  }
  if (route.page === 'detail') {
    return <SessionDetail key={routeKey} id={route.id} />;
  }
  return <SessionsList agents={agents} />;
}
