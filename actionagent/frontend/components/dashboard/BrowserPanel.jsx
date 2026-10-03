import React, { useEffect, useState } from 'react';
import { useTheme } from '../../contexts/ThemeContext';
import { apiErrorMessage } from '../../utils/codeSessions.mjs';
import { browserStartBody, browserStatus, isBrowserActive } from '../../utils/liveView.mjs';
import { StatusBadge } from './CodeSessionPanel';
import LiveView from './LiveView';

// A ready checkout sandbox's browser: start and stop it, its status, and,
// while it runs, its live view. `modes` is what the sandbox listing says the
// backend can start ("headless", and "headed" where it can open a window).
export default function BrowserPanel({ sandbox, modes }) {
  const { darkMode } = useTheme();
  const [browser, setBrowser] = useState(sandbox.browser || null);
  const [inWindow, setInWindow] = useState(false);
  const [busy, setBusy] = useState(null); // 'start' | 'stop'
  const [error, setError] = useState(null);
  const base = `/api/sandboxes/${encodeURIComponent(sandbox.session_id)}/browser`;

  // A fresh sandbox listing carries the browser as the server has it.
  useEffect(() => { setBrowser(sandbox.browser || null); }, [sandbox.browser?.status, sandbox.browser?.started_at, sandbox.browser?.live_url]);

  const request = async (action, init, fallback) => {
    setBusy(action);
    setError(null);
    try {
      const res = await fetch(base, init);
      const data = await res.json().catch(() => ({}));
      if (data.browser) setBrowser(data.browser);
      if (!res.ok) throw new Error(data.message || apiErrorMessage(data, `${fallback} (HTTP ${res.status}).`));
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(null);
    }
  };

  const start = () => request('start', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(browserStartBody({ inWindow, modes })),
  }, 'Could not start the browser');
  const stop = () => request('stop', { method: 'DELETE' }, 'Could not stop the browser');

  const muted = darkMode ? 'text-gray-400' : 'text-gray-500';
  const strong = darkMode ? 'text-white' : 'text-gray-900';
  const border = darkMode ? 'border-gray-700' : 'border-gray-200';
  const secondaryButton = `px-3 py-1 text-sm rounded disabled:opacity-50 ${darkMode ? 'bg-gray-700 text-gray-300 hover:bg-gray-600' : 'bg-gray-200 text-gray-700 hover:bg-gray-300'}`;
  const status = browserStatus(browser);
  const active = isBrowserActive(browser);
  const running = browser?.status === 'running';

  return (
    <div className={`mt-2 p-3 rounded-lg border space-y-3 ${border}`}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <p className={`text-sm font-medium ${strong}`}>Browser</p>
          {status && <StatusBadge tone={status.tone}>{status.label}</StatusBadge>}
        </div>
        {active ? (
          <button type="button" onClick={stop} disabled={busy !== null} className={secondaryButton}>
            {busy === 'stop' ? 'Stopping…' : 'Stop browser'}
          </button>
        ) : (
          <div className="flex items-center gap-3">
            {modes.includes('headed') && (
              <label className={`flex items-center gap-1 text-xs ${muted}`}>
                <input type="checkbox" checked={inWindow} onChange={(e) => setInWindow(e.target.checked)} disabled={busy !== null} />
                Open a window on this machine
              </label>
            )}
            <button type="button" onClick={start} disabled={busy !== null} className={secondaryButton}>
              {busy === 'start' ? 'Starting…' : 'Start browser'}
            </button>
          </div>
        )}
      </div>

      {error && <p className={`text-xs ${darkMode ? 'text-red-400' : 'text-red-600'}`} role="alert">{error}</p>}
      {!active && !error && (
        <p className={`text-xs ${muted}`}>
          A browser of this sandbox's own, opened on its app and recorded. Agent runs against the sandbox can drive it.
        </p>
      )}
      {running && browser.server_key && (
        <p className={`text-xs ${muted}`}>
          Runs against this sandbox reach it as <code className="font-mono">{browser.server_key}</code>.
        </p>
      )}
      {running && browser.live_url && <LiveView key={browser.started_at} sessionId={sandbox.session_id} headed={browser.mode === 'headed'} />}
      {running && !browser.live_url && <p className={`text-xs ${muted}`}>This browser has no live view to watch.</p>}
    </div>
  );
}
