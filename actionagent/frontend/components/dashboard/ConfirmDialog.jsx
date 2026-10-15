import React, { useCallback, useEffect, useId, useRef, useState } from 'react';
import { Button } from './primitives';
import {
  confirmTextMatches, currentConfirm, requestConfirm, settleConfirm, subscribeConfirm,
} from '../../utils/confirm.mjs';

const FOCUSABLE = 'button:not([disabled]), input:not([disabled]), [href], [tabindex]:not([tabindex="-1"])';

// The dashboard's confirmation dialog. `request` comes from utils/confirm.mjs;
// `onSettle(true|false)` answers it. With `requireText`, Confirm stays
// disabled until that text is typed exactly.
export function ConfirmDialog({ request, onSettle }) {
  const [typed, setTyped] = useState('');
  const dialogRef = useRef(null);
  const inputRef = useRef(null);
  const titleId = useId();
  const messageId = useId();
  const matches = confirmTextMatches(request, typed);

  // Initial focus on the input when typing is required, else on Cancel, so
  // Enter never confirms a destructive action by accident. Focus goes back to
  // whatever had it when the dialog closes.
  useEffect(() => {
    const previous = document.activeElement;
    if (request.requireText) inputRef.current?.focus();
    else dialogRef.current?.querySelector('[data-testid="confirm-cancel"]')?.focus();
    return () => previous?.focus?.();
  }, [request]);

  const accept = () => { if (matches) onSettle(true); };

  const onKeyDown = (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      onSettle(false);
      return;
    }
    if (event.key !== 'Tab') return;
    // Keep focus inside the dialog.
    const focusable = [...(dialogRef.current?.querySelectorAll(FOCUSABLE) || [])];
    if (focusable.length === 0) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  };

  const confirmStyle = request.danger ? { background: 'var(--color-error)', color: '#fff' } : undefined;

  return (
    <div
      data-testid="confirm-overlay"
      onMouseDown={(event) => { if (event.target === event.currentTarget) onSettle(false); }}
      style={{
        position: 'fixed', inset: 0, zIndex: 70, padding: 16,
        background: 'rgba(0, 0, 0, 0.5)', display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}
    >
      <div
        ref={dialogRef}
        role="alertdialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={messageId}
        data-testid="confirm-dialog"
        onKeyDown={onKeyDown}
        style={{
          width: '100%', maxWidth: 440, padding: 20, borderRadius: 12,
          background: 'var(--color-surface)', border: '1px solid var(--color-border)',
          color: 'var(--color-text-primary)', boxShadow: '0 20px 40px rgba(0, 0, 0, 0.25)',
        }}
      >
        <h2 id={titleId} style={{ margin: 0, fontSize: 16, fontWeight: 600 }}>{request.title}</h2>
        <div id={messageId}>
          {request.message && (
            <p style={{ margin: '8px 0 0', fontSize: 13, lineHeight: 1.5, color: 'var(--color-text-secondary)' }}>{request.message}</p>
          )}
          {request.requireText && (
            <label style={{ display: 'block', marginTop: 14, fontSize: 13, color: 'var(--color-text-secondary)' }}>
              Type <code style={{ fontFamily: 'var(--font-mono)', color: 'var(--color-text-primary)', fontWeight: 600 }}>{request.requireText}</code> to confirm.
              <input
                ref={inputRef}
                type="text"
                value={typed}
                autoComplete="off"
                spellCheck={false}
                data-testid="confirm-input"
                aria-label={`Type ${request.requireText} to confirm`}
                onChange={(event) => setTyped(event.target.value)}
                onKeyDown={(event) => { if (event.key === 'Enter') { event.preventDefault(); accept(); } }}
                style={{
                  display: 'block', width: '100%', marginTop: 6, padding: '8px 10px', borderRadius: 8, boxSizing: 'border-box',
                  fontFamily: 'var(--font-mono)', fontSize: 13, color: 'var(--color-text-primary)',
                  background: 'var(--color-background-page)', border: '1px solid var(--color-border-strong)',
                }}
              />
            </label>
          )}
        </div>
        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, marginTop: 18 }}>
          <Button testId="confirm-cancel" onClick={() => onSettle(false)}>{request.cancelLabel}</Button>
          <Button testId="confirm-confirm" variant="primary" onClick={accept} disabled={!matches} style={confirmStyle}>
            {request.confirmLabel}
          </Button>
        </div>
      </div>
    </div>
  );
}

// Renders the open confirmation, if any. Mounted once, inside the dashboard's
// token scope (pages/Dashboard.jsx), so the dialog follows the theme.
export function ConfirmHost() {
  const [request, setRequest] = useState(currentConfirm());
  useEffect(() => subscribeConfirm(setRequest), []);
  if (!request) return null;
  // Keyed on the request, so each one starts with an empty input.
  return <ConfirmDialog key={requestKey(request)} request={request} onSettle={settleConfirm} />;
}

const keys = new WeakMap();
let nextKey = 0;
function requestKey(request) {
  if (!keys.has(request)) keys.set(request, ++nextKey);
  return keys.get(request);
}

// Asks for confirmation in the dashboard's dialog:
//
//   const confirmAction = useConfirm();
//   if (!(await confirmAction({ title: 'Delete docsage?', danger: true, requireText: 'docsage' }))) return;
export function useConfirm() {
  return useCallback((options) => requestConfirm(options), []);
}
