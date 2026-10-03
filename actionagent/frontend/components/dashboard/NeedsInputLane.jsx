import React, { useState } from 'react';
import InputRequestCard from './InputRequestCard';
import { MicroLabel, MONO } from './primitives';
import { useInputRequests } from '../../hooks/useInputRequests';
import { pendingRequests } from '../../utils/inputRequests.mjs';

// The requests for input waiting on the people who can see their runs, at the
// top of Interactions. A request answered here stays on the lane with what
// became of it until the lane is left; the next refetch no longer lists it.

/**
 * @param {object} props
 * @param {Array} props.pending requests still waiting
 * @param {Array} [props.settled] `{ request, outcome }` for the ones answered here
 * @param {Function} [props.onSettled] (request, outcome)
 */
export function NeedsInputList({ pending, settled = [], onSettled }) {
  if (pending.length === 0 && settled.length === 0) return null;

  return (
    <section
      data-testid="needs-input-lane"
      aria-label="Needs input"
      style={{ border: '1px solid var(--color-warning)', borderRadius: 12, background: 'var(--color-warning-soft)', padding: 14, display: 'flex', flexDirection: 'column', gap: 10 }}
    >
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, flexWrap: 'wrap' }}>
        <MicroLabel color="var(--color-warning-text)">Needs input</MicroLabel>
        <span data-testid="needs-input-count" style={{ fontFamily: MONO, fontSize: 11, color: 'var(--color-warning-text)' }}>
          {pending.length} waiting
        </span>
        <span style={{ fontSize: 12, color: 'var(--color-text-secondary)' }}>
          Each run is paused until its request is answered. Answering continues the same run.
        </span>
      </div>
      {pending.map((request) => (
        <InputRequestCard key={request.id} request={request} onSettled={onSettled} />
      ))}
      {settled.map(({ request, outcome }) => (
        <InputRequestCard key={request.id} request={request} initialOutcome={outcome} />
      ))}
    </section>
  );
}

export default function NeedsInputLane({ agentId = null }) {
  const { requests } = useInputRequests({ agentId });
  const [settled, setSettled] = useState([]);

  const answeredHere = new Set(settled.map(({ request }) => request.id));
  const pending = pendingRequests(requests).filter((request) => !answeredHere.has(request.id));

  const recordSettled = (request, outcome) => {
    setSettled((previous) => [...previous.filter((entry) => entry.request.id !== request.id), { request, outcome }]);
  };

  return <NeedsInputList pending={pending} settled={settled} onSettled={recordSettled} />;
}
