import React, { useCallback, useEffect, useState } from 'react';
import { Badge, Button } from '../primitives';
import SandboxClaudeLogin, { FlowDialog, loginInputStyle, loginPanelStyle } from '../SandboxClaudeLogin';
import DraftPullRequestPanel from '../DraftPullRequestPanel';
import FixVerification from './FixVerification';
import { dashboardPath } from '../../../utils/dashboardPath';

const sameFix = (left, right) => left?.kind === right?.kind && (right?.kind === 'instruction' ? left?.quote === right?.quote : left?.fault === right?.fault)
  && [...(left?.scenario_keys || [])].sort().join('\0') === [...(right?.scenario_keys || [])].sort().join('\0')
  && (!(right?.models || []).length || [...(left?.models || [])].sort().join('\0') === [...right.models].sort().join('\0'));

export default function ImplementFixButton({ item, evaluation, run }) {
  const [open, setOpen] = useState(false);
  const [context, setContext] = useState(null);
  const [sandboxId, setSandboxId] = useState('');
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const [sessionId, setSessionId] = useState(null);
  const endpoint = `/api/evaluations/${evaluation?.id}/runs/${run?.id}/fixes`;
  const load = useCallback(async () => {
    const response = await fetch(endpoint);
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error || 'Could not load the fix workspace.');
    setContext(data);
    setSandboxId((current) => current || data.sandboxes?.find((sandbox) => sandbox.status === 'ready')?.session_id || '');
    return data;
  }, [endpoint]);
  useEffect(() => {
    if (!evaluation?.id || !run?.id) return undefined;
    let stopped = false;
    let timer;
    const poll = async () => {
      try { await load(); } catch (e) { if (!stopped) setError(e.message); }
      if (!stopped && open) timer = setTimeout(poll, 2500);
    };
    poll();
    return () => { stopped = true; clearTimeout(timer); };
  }, [load, open, evaluation?.id, run?.id]);
  if (!evaluation?.id || !run?.id || !['fault', 'instruction'].includes(item.kind)) return null;
  const sessions = (context?.code_sessions || []).filter((session) => sameFix(session.fix_item, item));
  const session = sessions.find((candidate) => candidate.id === sessionId) || sessions[0];
  const sandbox = context?.sandboxes?.find((candidate) => candidate.session_id === (session?.sandbox_session_id || sandboxId));
  const active = session && (['queued', 'running'].includes(session.status) || (session.status === 'succeeded' && session.diff && !session.verification?.error && !['complete', 'failed'].includes(session.verification?.status)));
  const connected = context?.auth_mode !== 'sandbox_login' || sandbox?.claude_login?.credential_mode;
  const implement = async (previous = null) => {
    if (!sandbox || busy || active) return;
    setBusy(true); setError(null);
    try {
      const response = await fetch(`/api/sandboxes/${encodeURIComponent(sandbox.session_id)}/code_sessions`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ evaluation_run_id: run.id, fix_item: { kind: item.kind, fault: item.fault, quote: item.quote, scenario_keys: item.scenario_keys, models: item.models }, previous_code_session_id: previous?.id }) });
      const data = await response.json();
      if (!response.ok) throw new Error(data.error || 'Could not start this fix.');
      setSessionId(data.code_session.id);
      await load();
    } catch (e) { setError(e.message); }
    finally { setBusy(false); }
  };
  const step = session ? (session.verification?.status === 'complete' ? 3 : session.status === 'succeeded' ? 2 : 1) : 0;
  return <>
    <Button size="sm" variant="primary" onClick={() => setOpen(true)} testId="implement-fix">{session ? 'Review implementation' : 'Implement with Claude Code'}</Button>
    {session?.verification?.status === 'complete' && <span style={{ fontSize: 11, color: 'var(--color-text-muted)' }}>{session.verification.counts.fixed || 0} fixed · {session.verification.counts.regressed || 0} regressed</span>}
    {open && <FlowDialog title="Implement evaluation fix" onClose={() => setOpen(false)}>
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>{['Connect', 'Implement', 'Verify', 'Draft PR'].map((label, index) => <Badge key={label} tone={index === step ? 'accent' : index < step ? 'success' : 'muted'}>{index + 1}. {label}</Badge>)}</div>
      <div><h3 style={{ margin: '0 0 8px', fontSize: 16 }}>{item.kind === 'instruction' ? 'Improve the instructions' : String(item.fault || '').replaceAll('_', ' ')}</h3><p style={{ margin: 0, fontSize: 13, lineHeight: '20px', color: 'var(--color-text-secondary)' }}>{item.quote || item.recommendation}</p></div>
      <div style={{ fontSize: 12, color: 'var(--color-text-muted)' }}>{item.scenario_keys?.length} scenarios · {item.models?.join(', ') || 'the original models'} · {evaluation.name}</div>
      {!context && <p role="status">Loading checkout sandboxes…</p>}
      {context?.refusal && <p role="alert" style={{ fontSize: 13, color: 'var(--color-warning-text)' }}>{context.refusal}</p>}
      {context && !context.supported && <p role="alert">This backend cannot refresh the checkout for verification.</p>}
      {!session && context?.sandboxes?.some((candidate) => candidate.status === 'ready') && <label style={{ fontSize: 12, fontWeight: 600 }}>Checkout sandbox<select aria-label="Checkout sandbox" style={{ ...loginInputStyle, marginTop: 8 }} value={sandboxId} onChange={(event) => setSandboxId(event.target.value)}><option value="">Choose a sandbox</option>{context.sandboxes.filter((candidate) => candidate.status === 'ready').map((candidate) => <option key={candidate.session_id} value={candidate.session_id}>{candidate.repository} · {candidate.repository_ref} · {candidate.session_id.slice(0, 8)}</option>)}</select></label>}
      {context && !sandbox && <div style={loginPanelStyle}><p style={{ fontSize: 13, marginTop: 0 }}>Start a checkout sandbox for this evaluation’s project, then return here to implement the fix.</p><a href={dashboardPath(context.project ? `/projects/${context.project.id}` : '/projects')}>Open {context.project?.name || 'Projects'} →</a><Button size="sm" onClick={() => load().catch((e) => setError(e.message))} style={{ marginLeft: 12 }}>Check again</Button></div>}
      {sandbox && context?.auth_mode === 'sandbox_login' && !active && <SandboxClaudeLogin sandbox={sandbox} onConnected={load} onChange={load} />}
      {sandbox && <p style={{ margin: 0, fontSize: 12, color: 'var(--color-text-secondary)' }}>This session will use <strong>{sandbox.claude_login?.credential_mode === 'sandbox_login' ? 'your Claude subscription' : context?.auth_mode === 'local_login' ? 'this machine’s Claude login' : connected ? 'the account’s Anthropic API key' : 'your sandbox login after you connect'}</strong>. Verification uses the agent’s own provider credentials.</p>}
      {!session && <Button variant="primary" disabled={!sandbox || !connected || busy || !!context?.refusal || !context?.supported} onClick={() => implement()}>{busy ? 'Starting…' : 'Implement this fix'}</Button>}
      {session && <>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}><Badge tone={session.status === 'failed' ? 'error' : 'info'}>Claude Code · {session.status}</Badge><span style={{ fontSize: 11, color: 'var(--color-text-muted)' }}>Session #{session.id}</span></div>
        {['queued', 'running'].includes(session.status) && <Button size="sm" onClick={async () => { try { const response = await fetch(`/api/sandboxes/${encodeURIComponent(sandbox.session_id)}/code_sessions/${session.id}/cancel`, { method: 'POST' }); if (!response.ok) throw new Error('Could not cancel this session.'); await load(); } catch (e) { setError(e.message); } }}>Cancel session</Button>}
        {session.result && <p style={{ fontSize: 13, lineHeight: '20px', whiteSpace: 'pre-wrap' }}>{session.result}</p>}
        {session.error_message && <p role="alert" style={{ color: 'var(--color-error-text)' }}>{session.error_message}</p>}
        {session.diff && <details><summary style={{ cursor: 'pointer', fontSize: 13 }}>Review code changes</summary><pre style={{ ...loginPanelStyle, maxHeight: 240, overflow: 'auto', fontSize: 11 }}>{session.diff}</pre></details>}
        <FixVerification session={session} evaluationId={evaluation.id} sandboxId={sandbox?.session_id} onRetry={() => implement(session)} />
        {session.verification?.status === 'complete' && sandbox && <DraftPullRequestPanel sandbox={sandbox} codeSession={session} />}
      </>}
      {error && <p role="alert" style={{ color: 'var(--color-error-text)', fontSize: 13 }}>{error}</p>}
    </FlowDialog>}
  </>;
}
