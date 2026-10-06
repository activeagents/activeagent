import React, { useCallback, useEffect, useState } from 'react';
import { Badge, Button, MicroLabel, MONO, Panel, SegmentedControl, TONE } from '../primitives';
import { apiErrorMessage } from '../../../utils/codeSessions.mjs';
import { signInPayload, signInResult } from '../../../utils/explorer.mjs';

const inputStyle = {
  width: '100%', padding: '6px 10px', borderRadius: 6, fontSize: 13, fontFamily: MONO,
  border: '1px solid var(--color-border)', background: 'var(--color-card)', color: 'var(--color-text-primary)',
};

const MODES = [
  { value: 'credentials', label: 'Seeded account' },
  { value: 'by_hand', label: 'Sign in by hand' },
  { value: 'none', label: 'No sign-in' },
];

const formatWhen = (iso) => (iso ? new Date(iso).toLocaleString() : '—');

async function send(path, method, body) {
  const res = await fetch(path, { method, headers: { 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(apiErrorMessage(data, `The request failed (HTTP ${res.status}).`));
  return data;
}

// The test account step (GET/PUT/DELETE /api/projects/:id/sign_in): how
// the project's browser signs in to the app. The credentials go to the
// engine, which types them into the app itself; the password is never shown
// back, and the explorer only names them. Signing in by hand opens the
// sandbox's browser in a window and keeps its sign-in.
export default function ProjectSignIn({ projectId, sandboxId, sandboxReady }) {
  const [signIn, setSignIn] = useState(null);
  const [mode, setMode] = useState(null);
  const [form, setForm] = useState({ login_url: '', login: '', password: '', login_field: '', password_field: '', submit_field: '' });
  const [result, setResult] = useState(null);
  const [error, setError] = useState(null);
  const [notice, setNotice] = useState(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const data = await send(`/api/projects/${projectId}/sign_in`, 'GET');
    setSignIn(data.sign_in);
    const credentials = data.sign_in?.credentials;
    if (credentials) setForm((current) => ({ ...current, login_url: credentials.login_url || '', login: credentials.login || '', ...credentials.fields }));
    setMode((current) => current || (credentials ? 'credentials' : data.sign_in?.storage_state ? 'by_hand' : 'none'));
  }, [projectId]);

  useEffect(() => {
    load().catch((e) => setError(e.message));
  }, [load]);

  const act = async (action) => {
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      await action();
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  };

  const credentials = signIn?.credentials;
  const { error: formError, payload } = signInPayload(form, { passwordSaved: Boolean(credentials?.password_set) });
  const checked = signInResult(result);

  const saveCredentials = () => act(async () => {
    const data = await send(`/api/projects/${projectId}/sign_in`, 'PUT', payload);
    setSignIn(data.sign_in);
    setForm((current) => ({ ...current, password: '' }));
    setNotice(data.warnings?.length ? data.warnings.map((warning) => warning.message).join(' ') : 'Saved. The explorer signs in with them.');
  });
  const check = () => act(async () => {
    const data = await send(`/api/projects/${projectId}/sign_in/check`, 'POST');
    setResult(data.result);
    setSignIn(data.sign_in);
  });
  const openWindow = () => act(async () => {
    await send(`/api/sandboxes/${sandboxId}/browser`, 'POST', { mode: 'headed' });
    await load();
    setNotice('A browser window opened on the app. Sign in there, then save its sign-in.');
  });
  const saveBrowser = () => act(async () => {
    const data = await send(`/api/projects/${projectId}/sign_in/save_browser`, 'POST');
    setSignIn(data.sign_in);
    setNotice('Saved. Every browser of this project now starts signed in.');
  });
  const stopBrowser = () => act(async () => {
    await send(`/api/sandboxes/${sandboxId}/browser`, 'DELETE');
    await load();
  });
  const clear = () => act(async () => {
    const data = await send(`/api/projects/${projectId}/sign_in`, 'DELETE');
    setSignIn(data.sign_in);
    setResult(null);
    setNotice('The explorer explores what is reachable without signing in.');
  });

  const field = (key, label, type = 'text', placeholder = '') => (
    <label style={{ display: 'flex', flexDirection: 'column', gap: 4, flex: '1 1 200px' }}>
      <MicroLabel>{label}</MicroLabel>
      <input
        type={type}
        autoComplete="off"
        value={form[key]}
        placeholder={placeholder}
        onChange={(event) => setForm({ ...form, [key]: event.target.value })}
        aria-label={label}
        style={inputStyle}
      />
    </label>
  );

  return (
    <Panel title="Sign-in" testId="project-sign-in" bodyStyle={{ padding: 12, display: 'flex', flexDirection: 'column', gap: 10 }}>
      <p style={{ margin: 0, fontSize: 13, color: 'var(--color-text-secondary)' }}>
        How the explorer and the evaluation's replays sign in to the app. Credentials are typed into the app by the dashboard
        itself and never reach a model.
      </p>
      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', alignItems: 'center' }}>
        {credentials && <Badge tone="success">credentials saved {formatWhen(credentials.updated_at)}</Badge>}
        {signIn?.storage_state && <Badge tone="success">browser sign-in saved {formatWhen(signIn.storage_state.updated_at)}</Badge>}
        {!credentials && !signIn?.storage_state && signIn && <Badge>no sign-in</Badge>}
      </div>
      <SegmentedControl options={MODES} value={mode || 'none'} onChange={setMode} />

      {mode === 'credentials' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }} data-testid="sign-in-credentials">
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            {field('login_url', 'Login URL', 'text', '/users/sign_in')}
            {field('login', 'Login', 'text', 'dev@example.com')}
            {field('password', 'Password', 'password', credentials?.password_set ? 'Saved; leave empty to keep it' : '')}
          </div>
          <details>
            <summary style={{ fontSize: 12, color: 'var(--color-text-secondary)', cursor: 'pointer' }}>Field selectors, when the form's fields are not found</summary>
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginTop: 6 }}>
              {field('login_field', 'Login field', 'text', '#user_email')}
              {field('password_field', 'Password field', 'text', '#user_password')}
              {field('submit_field', 'Submit button', 'text', 'button[type=submit]')}
            </div>
          </details>
          <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
            <Button variant="primary" size="sm" onClick={saveCredentials} disabled={busy || Boolean(formError)}>Save credentials</Button>
            <Button size="sm" onClick={check} disabled={busy || !credentials || !sandboxReady} testId="sign-in-check">Check sign-in</Button>
            {formError && <span style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>{formError}</span>}
          </div>
        </div>
      )}

      {mode === 'by_hand' && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }} data-testid="sign-in-by-hand">
          <p style={{ margin: 0, fontSize: 13, color: 'var(--color-text-secondary)' }}>
            Open the sandbox's browser in a window, sign in to the app there, then save its sign-in. Later browsers of this project
            start with it.
          </p>
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            <Button size="sm" onClick={openWindow} disabled={busy || !sandboxReady || signIn?.browser_running}>Open a browser window</Button>
            <Button variant="primary" size="sm" onClick={saveBrowser} disabled={busy || !signIn?.browser_running}>Save the browser's sign-in</Button>
            {signIn?.browser_running && <Button size="sm" variant="ghost" onClick={stopBrowser} disabled={busy}>Stop the browser</Button>}
          </div>
        </div>
      )}

      {mode === 'none' && (credentials || signIn?.storage_state) && (
        <div>
          <Button size="sm" variant="danger" onClick={clear} disabled={busy}>Remove the saved sign-in</Button>
        </div>
      )}

      {checked && (
        <div data-testid="sign-in-result" style={{ fontSize: 13, color: TONE[checked.tone]?.text || 'var(--color-text-secondary)' }}>{checked.text}</div>
      )}
      {notice && <div style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>{notice}</div>}
      {error && <div style={{ fontSize: 12, color: 'var(--color-error-text)' }}>{error}</div>}
    </Panel>
  );
}
