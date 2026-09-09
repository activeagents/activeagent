import React from 'react';
import { Badge, Empty, Glyph, MicroLabel, MonoLink, Panel, PassBar, MONO } from './primitives';
import { fmtCost, fmtMs, timeAgo } from '../../utils/format';
import { faultName, plural } from './EvaluationRunPanels';

// The compiled brief a code session hands to its coding agent, rendered as
// panels: what the agent under improvement needs, what it cannot do, the
// scenarios that failed, its production signal, and the sandbox the coding
// agent itself runs in. Purely presentational — the New form shows it as a
// live preview of `preview_brief`, the detail page shows the persisted copy —
// so it reads the section-4 `to_h` shape and nothing else.

const mono = (size = 11, color = 'var(--color-text-muted)', extra = {}) => ({ fontFamily: MONO, fontSize: size, color, ...extra });

// A need is red when a capability is missing outright, blue when it is a
// wording change, amber when it is something an operator provides.
const NEED_TONE = { tool: 'error', mcp_server: 'error', instruction: 'info', credential: 'warning', data: 'warning' };
const LIMITATION_TONE = { fault: 'error', quality: 'warning', reliability: 'error', latency: 'warning', cost: 'warning' };

const kindName = (kind) => String(kind || '').replace(/_/g, ' ');

export const briefCounts = (brief) => ({
  needs: (brief?.needs || []).length,
  limitations: (brief?.limitations || []).length,
  failing: (brief?.failing_scenarios || []).length,
});

// "expected tool not called ×3 · find_records_2, blame_1 · gpt-4o-mini"
function Evidence({ evidence }) {
  if (!evidence) return null;
  const parts = [];
  if (evidence.fault) parts.push(`${faultName(evidence.fault)}${evidence.count > 1 ? ` ×${evidence.count}` : ''}`);
  else if (evidence.count) parts.push(`×${evidence.count}`);
  if (evidence.scenario_keys?.length) parts.push(evidence.scenario_keys.join(', '));
  if (evidence.models?.length) parts.push(evidence.models.join(', '));
  if (parts.length === 0) return null;
  return <div style={{ ...mono(11), minWidth: 0, overflowWrap: 'anywhere' }}>{parts.join(' · ')}</div>;
}

function ToolChips({ tools }) {
  if (!tools?.length) return null;
  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
      {tools.map((tool) => (
        <span key={tool} style={{ padding: '2px 8px', borderRadius: 6, border: '1px solid var(--color-border)', fontFamily: MONO, fontSize: 11, fontWeight: 600, color: 'var(--color-text-primary)' }}>{tool}</span>
      ))}
    </div>
  );
}

function ItemRow({ glyph, tone, kind, title, detail, children, last }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 6, padding: '10px 12px', borderBottom: last ? 'none' : '1px solid var(--color-border-light)' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
        <Glyph kind={glyph} />
        <Badge tone={tone}>{kindName(kind)}</Badge>
        <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--color-text-primary)', minWidth: 0, textWrap: 'pretty' }}>{title}</span>
      </div>
      {detail && <div style={{ fontSize: 12, lineHeight: '18px', color: 'var(--color-text-cell)', textWrap: 'pretty' }}>{detail}</div>}
      {children}
    </div>
  );
}

export function NeedsPanel({ needs = [], onNavigate, meta }) {
  return (
    <Panel title="Needs" meta={meta ?? plural(needs.length, 'item')} testId="brief-needs">
      {needs.length === 0 ? (
        <Empty>[+] nothing the evaluations say it needs</Empty>
      ) : needs.map((need, index) => (
        <ItemRow
          key={`${need.kind}-${index}`}
          glyph={need.kind === 'instruction' ? 'info' : 'fault'}
          tone={NEED_TONE[need.kind] || 'muted'}
          kind={need.kind}
          title={need.title}
          detail={need.detail}
          last={index === needs.length - 1}
        >
          <ToolChips tools={need.tools} />
          {need.server && (
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', fontSize: 12, color: 'var(--color-text-cell)' }}>
              <span>served by</span>
              <span style={{ fontWeight: 600, color: 'var(--color-text-primary)' }}>{need.server.name || need.server.key}</span>
              <Badge tone={need.server.status === 'enabled' ? 'success' : 'warning'} size={10} style={{ padding: '1px 6px' }}>{need.server.status || 'unknown'}</Badge>
            </div>
          )}
          <Evidence evidence={need.evidence} />
          {need.action?.path && (
            <MonoLink onClick={() => onNavigate?.(need.action.path)}>{need.action.label || 'open'}</MonoLink>
          )}
        </ItemRow>
      ))}
    </Panel>
  );
}

export function LimitationsPanel({ limitations = [], meta }) {
  return (
    <Panel title="Limitations" meta={meta ?? plural(limitations.length, 'item')} testId="brief-limitations">
      {limitations.length === 0 ? (
        <Empty>[+] no limitations recorded</Empty>
      ) : limitations.map((item, index) => (
        <ItemRow
          key={`${item.kind}-${index}`}
          glyph="fault"
          tone={LIMITATION_TONE[item.kind] || 'muted'}
          kind={item.kind}
          title={item.title}
          detail={item.detail}
          last={index === limitations.length - 1}
        >
          <Evidence evidence={item.evidence} />
        </ItemRow>
      ))}
    </Panel>
  );
}

const SCENARIO_GRID = 'minmax(120px, 1fr) minmax(110px, 0.8fr) minmax(140px, 1fr) minmax(200px, 2fr)';

export function FailingScenariosPanel({ scenarios = [] }) {
  return (
    <Panel title="Failing scenarios" meta={plural(scenarios.length, 'scenario')} testId="brief-failing-scenarios" bodyStyle={{ overflowX: 'auto' }}>
      {scenarios.length === 0 ? (
        <Empty>[+] no failing scenarios in the seeding run</Empty>
      ) : (
        <div style={{ minWidth: 640 }}>
          <div style={{ display: 'grid', gridTemplateColumns: SCENARIO_GRID, gap: 12, padding: '6px 12px', borderBottom: '1px solid var(--color-border-light)' }}>
            {['scenario', 'model', 'fault', 'recommendation'].map((label) => <MicroLabel key={label} size={10} color="var(--color-text-muted)">{label}</MicroLabel>)}
          </div>
          {scenarios.map((row, index) => (
            <div
              key={`${row.key}-${row.model}-${index}`}
              title={row.prompt}
              style={{ display: 'grid', gridTemplateColumns: SCENARIO_GRID, gap: 12, padding: '8px 12px', alignItems: 'start', borderBottom: index === scenarios.length - 1 ? 'none' : '1px solid var(--color-border-light)' }}
            >
              <div style={{ minWidth: 0 }}>
                <div style={{ ...mono(11, 'var(--color-text-primary)'), fontWeight: 600, overflowWrap: 'anywhere' }}>{row.key}</div>
                {row.prompt && <div style={{ fontSize: 11, color: 'var(--color-text-muted)', marginTop: 2, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{row.prompt}</div>}
              </div>
              <span style={{ ...mono(11, 'var(--color-text-cell)'), overflowWrap: 'anywhere' }}>{row.model || '—'}</span>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 4, alignItems: 'flex-start' }}>
                <Badge tone="error">{faultName(row.fault) || 'fault'}</Badge>
                {row.tools_called?.length > 0 && <span style={mono(10)}>{`called ${row.tools_called.join(', ')}`}</span>}
              </div>
              <span style={{ fontSize: 12, lineHeight: '18px', color: 'var(--color-text-cell)', textWrap: 'pretty' }}>{row.recommendation || '—'}</span>
            </div>
          ))}
        </div>
      )}
    </Panel>
  );
}

function Stat({ label, value, color }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 4, minWidth: 0 }}>
      <MicroLabel size={10} color="var(--color-text-muted)">{label}</MicroLabel>
      <span style={{ fontFamily: MONO, fontSize: 18, fontWeight: 700, lineHeight: 1.1, color: color || 'var(--color-text-primary)' }}>{value}</span>
    </div>
  );
}

const pct = (value) => (value == null ? '—' : `${Number(value).toFixed(1)}%`);

export function MetricsPanel({ metrics }) {
  const window = metrics?.window || '24h';
  return (
    <Panel title="Production signal" meta={`last ${window}`} testId="brief-metrics">
      {!metrics ? (
        <Empty>[ ] no telemetry for this agent in the window</Empty>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12, padding: '12px' }}>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(96px, 1fr))', gap: 12 }}>
            <Stat label="requests" value={metrics.requests ?? '—'} />
            <Stat label="error rate" value={pct(metrics.error_rate)} color={metrics.error_rate > 5 ? 'var(--color-error)' : undefined} />
            <Stat label="p50" value={metrics.p50_ms == null ? '—' : fmtMs(metrics.p50_ms)} />
            <Stat label="p95" value={metrics.p95_ms == null ? '—' : fmtMs(metrics.p95_ms)} color={metrics.p95_ms > 10000 ? 'var(--color-warning)' : undefined} />
            <Stat label="cost" value={fmtCost(metrics.cost, 2)} />
            <Stat label="tool errors" value={pct(metrics.tool_error_rate)} />
          </div>
          {metrics.errors_by_type && Object.keys(metrics.errors_by_type).length > 0 && (
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, alignItems: 'center' }}>
              <MicroLabel size={10} color="var(--color-text-muted)">errors</MicroLabel>
              {Object.entries(metrics.errors_by_type).map(([type, count]) => (
                <Badge key={type} tone="error" size={10}>{`${type} ×${count}`}</Badge>
              ))}
            </div>
          )}
        </div>
      )}
    </Panel>
  );
}

// The sandbox and the coding agent's own needs and limitations: the part of
// the brief that is about the fixer rather than the agent being fixed.
export function SandboxPanel({ sandbox, codeAgent }) {
  const constraints = sandbox?.constraints || [];
  const present = codeAgent?.credentials_present || [];
  const missing = codeAgent?.credentials_missing || [];
  return (
    <Panel title="Sandbox" meta={sandbox?.backend || null} testId="brief-sandbox">
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12, padding: 12 }}>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: '6px 16px', ...mono(11, 'var(--color-text-cell)') }}>
          <span>{`network ${sandbox?.network_mode || '—'}`}</span>
          <span>{`github ${sandbox?.github_access || 'none'}`}</span>
          <span style={{ overflowWrap: 'anywhere' }}>{`repo ${sandbox?.repository || 'scratch workspace'}`}</span>
        </div>

        {constraints.length > 0 && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
            {constraints.map((line) => (
              <div key={line} style={{ display: 'flex', gap: 8, fontSize: 12, lineHeight: '18px', color: 'var(--color-text-cell)' }}>
                <Glyph kind="info" style={{ marginTop: 3 }} />
                <span style={{ textWrap: 'pretty' }}>{line}</span>
              </div>
            ))}
          </div>
        )}

        {codeAgent && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8, paddingTop: 10, borderTop: '1px solid var(--color-border-light)' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
              <MicroLabel size={10} color="var(--color-text-muted)">coding agent</MicroLabel>
              <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--color-text-primary)' }}>{codeAgent.name || codeAgent.tool}</span>
              <Badge tone={codeAgent.headless ? 'success' : 'warning'} size={10}>{codeAgent.headless ? 'headless' : 'attach to drive'}</Badge>
              {codeAgent.experimental && <Badge tone="warning" size={10}>experimental</Badge>}
            </div>
            {(present.length > 0 || missing.length > 0) && (
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: '4px 12px', ...mono(11) }}>
                {present.map((name) => <span key={name} style={{ color: 'var(--color-success-text)' }}>{`[+] ${name}`}</span>)}
                {missing.map((name) => <span key={name} style={{ color: 'var(--color-error-text)' }}>{`[!] ${name} missing`}</span>)}
              </div>
            )}
            {(codeAgent.needs || []).map((line) => (
              <div key={line} style={{ display: 'flex', gap: 8, fontSize: 12, lineHeight: '18px', color: 'var(--color-text-cell)' }}>
                <Glyph kind="fault" color="var(--color-warning)" style={{ marginTop: 3 }} />
                <span style={{ textWrap: 'pretty' }}>{line}</span>
              </div>
            ))}
            {(codeAgent.limitations || []).map((line) => (
              <div key={line} style={{ display: 'flex', gap: 8, fontSize: 12, lineHeight: '18px', color: 'var(--color-text-secondary)' }}>
                <Glyph kind="info" style={{ marginTop: 3 }} />
                <span style={{ textWrap: 'pretty' }}>{line}</span>
              </div>
            ))}
          </div>
        )}
      </div>
    </Panel>
  );
}

// Where the brief came from: the agent, and the run whose findings seeded it.
export function SourcePanel({ agent, evaluation, generatedAt }) {
  const passed = evaluation?.passed ?? 0;
  const total = evaluation?.scenarios ?? 0;
  return (
    <Panel title="Source" meta={generatedAt ? `compiled ${timeAgo(generatedAt)}` : null} testId="brief-source">
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: '8px 24px', padding: 12, alignItems: 'center' }}>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, minWidth: 0 }}>
          <span style={{ fontFamily: MONO, fontSize: 12, color: 'var(--color-text-muted)' }}>@</span>
          <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--color-text-primary)' }}>{agent?.name || 'agent'}</span>
          <span style={mono(11)}>{[agent?.provider, agent?.model].filter(Boolean).join('/') || '—'}</span>
        </div>
        {agent?.tools?.length > 0 && <span style={mono(11)}>{`tools ${agent.tools.join(', ')}`}</span>}
        {agent?.mcp_servers?.length > 0 && <span style={mono(11)}>{`mcp ${agent.mcp_servers.join(', ')}`}</span>}
        <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
          {evaluation ? (
            <>
              <span style={mono(11, 'var(--color-text-cell)')}>{`${evaluation.name || 'evaluation'} · run ${evaluation.run_id}`}</span>
              {evaluation.kind === 'scenario' && total > 0 ? (
                <PassBar passed={passed} total={total} width={96} />
              ) : (
                <Badge tone="muted">{evaluation.kind || 'sampled'}</Badge>
              )}
            </>
          ) : (
            <span style={mono(11)}>no evaluation run — the brief carries only the sandbox and metrics</span>
          )}
        </div>
      </div>
    </Panel>
  );
}

// The full brief. `compact` drops the source strip (the New form already
// shows those choices as inputs).
export default function CodeSessionBrief({ brief, onNavigate, compact = false }) {
  if (!brief) return null;
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }} data-testid="code-session-brief">
      {!compact && <SourcePanel agent={brief.agent} evaluation={brief.evaluation} generatedAt={brief.generated_at} />}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))', gap: 12, alignItems: 'start' }}>
        <NeedsPanel needs={brief.needs} onNavigate={onNavigate} />
        <LimitationsPanel limitations={brief.limitations} />
      </div>
      <FailingScenariosPanel scenarios={brief.failing_scenarios} />
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(320px, 1fr))', gap: 12, alignItems: 'start' }}>
        <MetricsPanel metrics={brief.metrics} />
        <SandboxPanel sandbox={brief.sandbox} codeAgent={brief.code_agent} />
      </div>
    </div>
  );
}
