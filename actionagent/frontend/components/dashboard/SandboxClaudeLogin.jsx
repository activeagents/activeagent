import React, { useEffect, useRef, useState } from 'react';
import { Badge, Button } from './primitives';

export const loginPanelStyle = { padding: 16, border: '1px solid var(--color-border)', borderRadius: 12, background: 'var(--color-muted)', color: 'var(--color-text-primary)' };
export const loginInputStyle = { width: '100%', boxSizing: 'border-box', padding: '12px 14px', borderRadius: 8, border: '1px solid var(--color-border)', background: 'var(--color-background)', color: 'var(--color-text-primary)', fontFamily: 'var(--font-mono)', fontSize: 13 };

export function FlowDialog({ title, onClose, children }) {
  const ref = useRef(null);
  useEffect(() => {
    const dialog = ref.current;
    dialog?.showModal?.();
    return () => dialog?.close?.();
  }, []);
  return <dialog ref={ref} className="aa-fix-dialog" aria-label={title} onCancel={(event) => { event.preventDefault(); onClose(); }}
    style={{ width: 'min(760px, calc(100vw - 32px))', maxHeight: 'calc(100dvh - 40px)', boxSizing: 'border-box', padding: 0, borderRadius: 16, border: '1px solid var(--color-border)', background: 'var(--color-card, var(--color-background))', color: 'var(--color-text-primary)' }}>
    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 12, padding: '20px 24px', borderBottom: '1px solid var(--color-border)' }}>
      <h2 style={{ margin: 0, fontSize: 19, letterSpacing: '-0.02em' }}>{title}</h2>
      <button type="button" aria-label="Close dialog" onClick={onClose} style={{ background: 'none', border: 0, color: 'var(--color-text-secondary)', cursor: 'pointer', fontSize: 24 }}>×</button>
    </div>
    <div style={{ padding: 24, display: 'flex', flexDirection: 'column', gap: 18 }}>{children}</div>
  </dialog>;
}

async function request(base, method = 'GET', body) {
  const response = await fetch(base, { method, headers: body ? { 'Content-Type': 'application/json' } : undefined, body: body ? JSON.stringify(body) : undefined, cache: 'no-store' });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || 'Could not connect Claude Code. Please try again.');
  return data.login;
}

export const signInEnded = (status) => {
  if (status === 'expired') return 'This sign-in expired. Start again to get a fresh authorization page.';
  if (status === 'completed') return 'Claude Code signed in, but not with a Claude subscription. Start again and choose your Claude.ai account.';
  return 'Sign-in did not finish. Start again to retry.';
};

export default function SandboxClaudeLogin({ sandbox, onConnected, onChange }) {
  const base = `/api/sandboxes/${encodeURIComponent(sandbox.session_id)}/claude_login`;
  const [login, setLogin] = useState(null);
  const [open, setOpen] = useState(false);
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const authTab = useRef(null);
  const connectedCallback = useRef(onConnected);
  connectedCallback.current = onConnected;

  useEffect(() => {
    let cancelled = false;
    request(base).then((value) => { if (!cancelled) setLogin(value); }).catch((e) => { if (!cancelled) setError(e.message); });
    return () => { cancelled = true; };
  }, [base]);

  useEffect(() => {
    if (!open) return undefined;
    let cancelled = false;
    let timer;
    const poll = async () => {
      try {
        const value = await request(base);
        if (cancelled) return;
        setLogin(value);
        if (value.authorize_url && authTab.current) {
          authTab.current.location = value.authorize_url;
          authTab.current = null;
        }
        if (value.logged_in) {
          setOpen(false); setCode(''); setBusy(false);
          onChange?.(); connectedCallback.current?.();
          return;
        }
        // Every state but the three a sign-in moves through is an end: one
        // without a login (logged_in was handled above) is a failure, and
        // polling on would only ask the CLI again and again.
        if (!['starting', 'awaiting_code', 'submitted'].includes(value.status)) {
          setError(signInEnded(value.status));
          setBusy(false);
          return;
        }
        timer = setTimeout(poll, 1200);
      } catch (e) { if (!cancelled) { setError(e.message); setBusy(false); } }
    };
    timer = setTimeout(poll, 300);
    return () => { cancelled = true; clearTimeout(timer); };
  }, [base, open]);

  const start = async () => {
    setError(null); setCode(''); setBusy(true);
    // Open during the click gesture so mobile browsers do not block the
    // CLI's URL when it arrives. A visible link remains if they do.
    authTab.current = window.open('about:blank', '_blank');
    if (authTab.current) authTab.current.opener = null;
    try { setLogin(await request(base, 'POST')); setOpen(true); }
    catch (e) { authTab.current?.close(); authTab.current = null; setError(e.message); }
    finally { setBusy(false); }
  };
  const disconnect = async () => {
    authTab.current?.close(); authTab.current = null;
    setCode(''); setOpen(false); setBusy(true);
    try { setLogin(await request(base, 'DELETE')); onChange?.(); }
    catch (e) { setError(e.message); }
    finally { setBusy(false); }
  };
  const submit = async (event) => {
    event.preventDefault();
    if (!code.trim() || busy) return;
    const value = code.trim();
    setCode(''); setBusy(true); setError(null);
    try { setLogin(await request(`${base}/code`, 'POST', { claude_login_code: value })); }
    catch (e) { setError(e.message); setBusy(false); }
  };

  return <section style={loginPanelStyle} data-testid="sandbox-claude-login">
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 10 }}>
      <div style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 8 }}><strong>Claude Code</strong><Badge tone={login?.logged_in ? 'success' : 'accent'}>{login?.logged_in ? 'Your subscription connected' : 'Use your Claude subscription'}</Badge></div>
      {login?.logged_in && <Button size="sm" variant="ghost" onClick={disconnect} disabled={busy}>Disconnect</Button>}
    </div>
    <p style={{ fontSize: 13, lineHeight: '20px', color: 'var(--color-text-secondary)', margin: '10px 0' }}>Usage counts against your own Claude Pro, Max, or Team plan. Your login stays inside this sandbox and ends when the sandbox stops.</p>
    {!login?.logged_in && <Button variant="primary" onClick={start} disabled={busy || sandbox.status !== 'ready'}>{busy ? 'Connecting…' : 'Sign in with your Claude subscription'}</Button>}
    {error && !open && <p role="alert" style={{ color: 'var(--color-error-text)', fontSize: 13 }}>{error}</p>}
    {open && <FlowDialog title="Connect your Claude subscription" onClose={disconnect}>
      <p style={{ margin: 0, fontSize: 14, lineHeight: '22px', color: 'var(--color-text-secondary)' }}>Authorize Claude Code on Claude’s website. Then paste the one-time code below to finish signing in to this sandbox.</p>
      <div style={{ ...loginPanelStyle, fontSize: 12 }}><strong>{sandbox.repository || 'Checkout sandbox'}</strong><div style={{ marginTop: 6, fontFamily: 'var(--font-mono)', color: 'var(--color-text-muted)' }}>{sandbox.session_id}</div></div>
      {login?.authorize_url ? <a href={login.authorize_url} target="_blank" rel="noreferrer" style={{ color: 'var(--color-text-link, var(--color-accent-ui))', fontSize: 13 }}>Reopen Claude authorization page ↗</a> : <p role="status" style={{ fontSize: 13 }}>{login?.status === 'submitted' ? 'Confirming your sign-in…' : 'Preparing Claude’s authorization page…'}</p>}
      <form onSubmit={submit} style={{ display: 'flex', flexDirection: 'column', gap: 12 }} data-aa-secret="">
        <label htmlFor={`claude-login-code-${sandbox.session_id}`} style={{ fontSize: 12, fontWeight: 600 }}>Authentication code</label>
        <input id={`claude-login-code-${sandbox.session_id}`} type="password" data-aa-secret="" autoComplete="off" spellCheck={false} maxLength={2048} value={code} onChange={(event) => setCode(event.target.value)} placeholder="Paste the code from Claude" style={loginInputStyle} disabled={busy || login?.status !== 'awaiting_code'} />
        <Button variant="primary" type="submit" disabled={!code.trim() || busy || login?.status !== 'awaiting_code'}>{busy ? 'Completing connection…' : 'Complete connection'}</Button>
      </form>
      {error && <><p role="alert" style={{ color: 'var(--color-error-text)', fontSize: 13 }}>{error}</p><Button onClick={start} disabled={busy}>Start sign-in again</Button></>}
      <p style={{ margin: 0, fontSize: 12, lineHeight: '18px', color: 'var(--color-text-muted)' }}>The code is sent once to Claude Code running in your sandbox. ActiveAgent does not store your Claude subscription token.</p>
    </FlowDialog>}
  </section>;
}
