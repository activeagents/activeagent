import React, { useState } from 'react';
import GenerativeUI from './GenerativeUI';
import { Badge, Button, MonoLink, MONO } from './primitives';
import { useTheme } from '../../contexts/ThemeContext';
import { dashboardPath, navigateTo } from '../../utils/dashboardPath';
import { notifyInputRequestsChanged } from '../../hooks/useInputRequests';
import {
  actorLabel,
  answerBlocks,
  answerControl,
  answerFromUiAction,
  askedLabel,
  confirmArguments,
  expiryLabel,
  isSettled,
  runPath,
  settleInputRequest,
  settledLabel,
} from '../../utils/inputRequests.mjs';

// One request for input and the control that answers it. Every surface that
// answers a request renders this card: the Needs input lane, the runner and
// the Project page.
//
// It says who is asking (the agent, its run, the person the run acts for and
// the tool) and when the request expires, then offers the control the kind
// takes. It posts to the answer and decline endpoints and never starts a run:
// the server resumes the paused one.

const KIND_LABELS = { text: 'question', choice: 'choice', confirm: 'approval', secret: 'secret' };
const OUTCOME_TONES = { answered: 'success', declined: 'muted', closed: 'warning' };

const meta = { fontFamily: MONO, fontSize: 11, color: 'var(--color-text-muted)' };

const fieldStyle = {
  flex: 1,
  minWidth: 0,
  padding: '7px 10px',
  borderRadius: 8,
  border: '1px solid var(--color-border-strong)',
  background: 'var(--color-surface)',
  color: 'var(--color-text-primary)',
  fontFamily: MONO,
  fontSize: 13,
};

// The masked field a `secret` request is answered in. The value lives only in
// this field's state, which is emptied the moment it is sent, and
// `data-aa-secret` marks it for masking by anything that captures the page.
function SecretField({ request, busy, onSubmit }) {
  const [value, setValue] = useState('');
  const submit = (event) => {
    event.preventDefault();
    if (!value || busy) return;
    const answer = value;
    setValue('');
    onSubmit(answer);
  };

  return (
    <form onSubmit={submit} style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
      <input
        type="password"
        autoComplete="off"
        spellCheck={false}
        data-aa-secret=""
        data-testid="input-request-secret"
        aria-label={request.prompt}
        value={value}
        onChange={(event) => setValue(event.target.value)}
        disabled={busy}
        style={fieldStyle}
      />
      <Button type="submit" variant="primary" size="sm" disabled={busy || !value} testId="input-request-secret-submit">
        {busy ? 'Sending…' : 'Send'}
      </Button>
    </form>
  );
}

function ConfirmControl({ request, busy, onApprove, onDecline }) {
  const args = confirmArguments(request);
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      {args && (
        <pre
          data-testid="input-request-arguments"
          style={{
            margin: 0, padding: '8px 10px', borderRadius: 8, maxHeight: 200, overflow: 'auto', whiteSpace: 'pre-wrap',
            background: 'var(--color-muted)', color: 'var(--color-text-cell)', fontFamily: MONO, fontSize: 12,
          }}
        >
          {args}
        </pre>
      )}
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        <Button variant="primary" size="sm" onClick={onApprove} disabled={busy} testId="input-request-approve">Approve</Button>
        <Button variant="secondary" size="sm" onClick={onDecline} disabled={busy} testId="input-request-decline">Decline</Button>
      </div>
    </div>
  );
}

/**
 * @param {object} props
 * @param {object} props.request an entry of GET /api/input_requests
 * @param {Function} [props.onSettled] called with (request, outcome) once the
 *   request is answered, declined, or found already closed
 * @param {object} [props.initialOutcome] shows the card settled, as an
 *   earlier answer left it
 * @param {boolean} [props.showRunLink] links the run; off where the run is
 *   already on screen
 */
export default function InputRequestCard({ request, onSettled, initialOutcome = null, showRunLink = true }) {
  const { darkMode } = useTheme();
  const [busy, setBusy] = useState(false);
  const [outcome, setOutcome] = useState(initialOutcome);

  const control = answerControl(request);
  const settled = isSettled(outcome);

  const send = async (payload) => {
    if (busy || settled) return;
    setBusy(true);
    const result = await settleInputRequest(request, payload);
    setBusy(false);
    setOutcome(result);
    if (isSettled(result)) {
      notifyInputRequestsChanged();
      if (onSettled) onSettled(request, result);
    }
  };

  const answer = (value) => {
    if (value === undefined) return;
    send({ answer: value });
  };
  const decline = () => send({ decline: true });

  const link = showRunLink ? runPath(request) : null;
  const actor = actorLabel(request.actor);
  const expiry = expiryLabel(request.expires_at);
  const asked = askedLabel(request.created_at);

  return (
    <div
      data-testid="input-request-card"
      data-kind={request.kind}
      data-state={outcome?.state || 'pending'}
      style={{ border: '1px solid var(--color-border)', borderRadius: 10, background: 'var(--color-card)', padding: '12px 14px', display: 'flex', flexDirection: 'column', gap: 8 }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
        <Badge tone={request.kind === 'confirm' ? 'warning' : 'info'} size={10}>{KIND_LABELS[request.kind] || request.kind}</Badge>
        <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--color-text-primary)' }}>
          {request.agent?.name || 'An agent'} is asking
        </span>
        {link && (
          <MonoLink
            href={dashboardPath(link)}
            onClick={() => navigateTo(link)}
            title="Open the run this request paused"
          >
            <span data-testid="input-request-run-link">run #{request.run_id}</span>
          </MonoLink>
        )}
        {expiry && (
          <span style={{ ...meta, marginLeft: 'auto', color: expiry === 'expired' ? 'var(--color-error-text)' : meta.color }}>{expiry}</span>
        )}
      </div>

      <div style={{ fontSize: 14, color: 'var(--color-text-primary)', whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{request.prompt}</div>

      <div style={{ ...meta, display: 'flex', gap: 10, flexWrap: 'wrap' }}>
        {actor && <span data-testid="input-request-actor">for {actor}</span>}
        {request.tool_name && <span data-testid="input-request-tool">via {request.tool_name}</span>}
        {asked && <span>{asked}</span>}
      </div>

      {settled ? (
        <div data-testid="input-request-outcome">
          <Badge tone={OUTCOME_TONES[outcome.state] || 'muted'}>{settledLabel(request, outcome)}</Badge>
        </div>
      ) : (
        <>
          {(control === 'text' || control === 'choice') && (
            <GenerativeUI blocks={answerBlocks(request)} darkMode={darkMode} onAction={(action) => answer(answerFromUiAction(request, action))} />
          )}
          {control === 'confirm' && (
            <ConfirmControl request={request} busy={busy} onApprove={() => answer(true)} onDecline={decline} />
          )}
          {control === 'secret' && <SecretField request={request} busy={busy} onSubmit={answer} />}
          {control !== 'confirm' && (
            <div>
              <Button variant="ghost" size="sm" onClick={decline} disabled={busy} testId="input-request-decline" style={{ padding: '2px 0' }}>
                Decline
              </Button>
            </div>
          )}
          {outcome?.message && (
            <div data-testid="input-request-error" role="alert" style={{ fontSize: 12, color: 'var(--color-error-text)' }}>
              {outcome.message}
            </div>
          )}
        </>
      )}
    </div>
  );
}
