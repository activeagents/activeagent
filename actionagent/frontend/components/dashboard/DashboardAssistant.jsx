import React, { useEffect, useRef, useState } from 'react';
import { Badge, Button, Card, MicroLabel, MONO } from './primitives';
import { dashboardPath } from '../../utils/dashboardPath';

const STARTERS = [
  { label: 'Find demo questions', message: 'What demo questions worked in our latest evaluations? Show the evidence and tell me whether they are verified on current main.' },
  { label: 'Explain a failed eval', message: 'Show my latest evaluation reports and explain which failures need attention.' },
  { label: 'Draft an agent', message: 'Prepare a read-only support agent that cites available evidence and explains missing information instead of inventing answers.' },
];

const field = { width: '100%', background: 'var(--color-card)', color: 'var(--color-text-primary)', border: '1px solid var(--color-border-strong)', borderRadius: 8, padding: '9px 12px', font: 'inherit' };
const muted = { color: 'var(--color-text-muted)', fontSize: 12 };

// Links are issued by the evidence service, not parsed out of model prose.
function evidencePath(card) {
  const path = card.latest_run?.path || card.path || '';
  return /^\/evaluations(?:\/\d+\/runs\/\d+\/report)?$/.test(path) ? dashboardPath(path) : null;
}

function EvidenceCard({ card, onAsk, busy }) {
  const path = evidencePath(card);
  const historical = card.type === 'demo_candidate';
  const run = card.run_id || card.latest_run?.run_id;
  const status = card.status || card.latest_run?.status;
  const failed = status === 'errored' || status === 'failed';
  return (
    <Card padding={16} testId="assistant-evidence-card" style={{ display: 'grid', gap: 10 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
        <Badge tone={historical ? 'warning' : 'info'}>{historical ? 'Historical pass' : 'Recorded evaluation'}</Badge>
        {status && <Badge tone={failed ? 'error' : 'muted'}>{status}</Badge>}
        {card.check_strength && <span style={muted}>{String(card.check_strength).replaceAll('_', ' ')}</span>}
      </div>
      <div style={{ fontWeight: 600, overflowWrap: 'anywhere' }}>{card.recorded_prompt || card.title}</div>
      <div style={{ ...muted, fontFamily: MONO }}>
        {[card.provider, card.model, run && `run ${run}`].filter(Boolean).join(' · ')}
        {card.completed_at && ` · ${new Date(card.completed_at).toLocaleString()}`}
      </div>
      {card.output_excerpt && <div style={{ fontSize: 13, whiteSpace: 'pre-wrap', color: 'var(--color-text-secondary)' }}>{card.output_excerpt}</div>}
      {(card.error || card.latest_run?.error) && <div style={{ fontSize: 13, whiteSpace: 'pre-wrap', color: 'var(--color-error)' }}>{card.error || card.latest_run.error}</div>}
      {card.fault && <div style={muted}>Fault: {card.fault.replaceAll('_', ' ')}</div>}
      {card.samples_evaluated != null && <div style={muted}>{card.samples_passed || 0} / {card.samples_evaluated} scenarios passed</div>}
      {card.tool_names?.length > 0 && <div style={muted}>Tools recorded: {card.tool_names.join(', ')}</div>}
      {Array.isArray(card.caveats) && card.caveats.length > 0 && (
        <details style={muted}>
          <summary style={{ cursor: 'pointer' }}>Evidence limits</summary>
          <ul style={{ paddingLeft: 18, marginTop: 8 }}>{card.caveats.map((item, i) => <li key={i}>{item}</li>)}</ul>
        </details>
      )}
      <div style={{ display: 'flex', gap: 12, alignItems: 'center', flexWrap: 'wrap' }}>
        {path && <a href={path} target="_blank" rel="noopener noreferrer" style={{ fontSize: 13, color: 'var(--color-accent-ui)' }}>{path === dashboardPath('/evaluations') ? 'Open evaluations →' : 'Open report →'}</a>}
        {card.evaluation_id && run && (
          <Button size="sm" disabled={busy} onClick={() => onAsk(`Read evaluation ${card.evaluation_id}, run ${run}. Explain its results, the strength of its checks, and what needs fixing.`)}>Explain this run</Button>
        )}
      </div>
    </Card>
  );
}

function AgentDraft({ draft, onReview }) {
  return (
    <Card padding={18} testId="assistant-agent-draft" style={{ display: 'grid', gap: 12, borderColor: 'var(--color-accent-ui)' }}>
      <MicroLabel>Agent draft · not saved</MicroLabel>
      <div style={{ fontWeight: 600, fontSize: 18 }}>{draft.name}</div>
      <p style={{ margin: 0, color: 'var(--color-text-secondary)', fontSize: 13 }}>{draft.description}</p>
      <div style={{ ...muted, fontFamily: MONO }}>{draft.provider} / {draft.model}</div>
      <details>
        <summary style={{ cursor: 'pointer', fontSize: 13 }}>Review instructions and tools</summary>
        <pre style={{ whiteSpace: 'pre-wrap', fontFamily: 'inherit', fontSize: 13, maxHeight: 280, overflow: 'auto' }}>{draft.instructions}</pre>
        <p style={muted}>Tools: {draft.tools?.length ? draft.tools.join(', ') : 'None'}</p>
      </details>
      <Button variant="primary" onClick={() => onReview(draft)} style={{ justifySelf: 'start' }}>Review in builder →</Button>
    </Card>
  );
}

export default function DashboardAssistant({ session, onSessionChange, onReviewDraft, onOpenSettings, executionEnabled = true }) {
  const [configuration, setConfiguration] = useState(null);
  const [input, setInput] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const [allowProviderProcessing, setAllowProviderProcessing] = useState(false);
  const abortRef = useRef(null);
  const formRef = useRef(null);
  const sessionRef = useRef(session);
  sessionRef.current = session;

  useEffect(() => {
    const controller = new AbortController();
    fetch('/api/dashboard_assistant', { signal: controller.signal })
      .then(async response => {
        const data = await response.json();
        if (!response.ok) throw new Error(data.error || 'Could not load assistant configuration.');
        setConfiguration(data);
        if (!sessionRef.current.provider) onSessionChange({ ...sessionRef.current, ...data.defaults });
      })
      .catch(e => { if (e.name !== 'AbortError') setError({ message: e.message }); });
    return () => { controller.abort(); abortRef.current?.abort(); };
  }, []);

  const messages = session.messages || [];
  const provider = session.provider || configuration?.defaults?.provider || '';
  const model = session.model || '';
  const limit = configuration?.limits?.message_characters || 8000;
  const configuredProvider = configuration?.providers?.find(item => item.id === provider);

  const ask = async text => {
    const message = text.trim();
    if (!message || busy || !configuration || !executionEnabled || !model.trim() || !allowProviderProcessing) return;
    const history = messages.map(item => ({ role: item.role, content: item.content })).slice(-12);
    while (history.reduce((size, item) => size + item.content.length, 0) > 24000) history.shift();
    const updated = [...messages, { role: 'user', content: message }];
    onSessionChange({ ...session, messages: updated });
    setInput('');
    setError(null);
    setBusy(true);
    const controller = new AbortController();
    abortRef.current = controller;
    try {
      const response = await fetch('/api/dashboard_assistant', {
        method: 'POST', signal: controller.signal,
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '' },
        body: JSON.stringify({ message, history, provider, model: model.trim(), allow_provider_processing: true }),
      });
      const data = await response.json();
      if (!response.ok) {
        setError({ message: typeof data.error === 'string' ? data.error : 'The assistant could not complete this request.', setup: data.setup_required, retry: message });
        // A rejected request is not a conversational answer and must not be
        // replayed as successful history on a later turn.
        onSessionChange({ ...session, messages });
        setInput(message);
        return;
      }
      onSessionChange({ ...session, messages: [...updated, {
        role: 'assistant', content: data.answer, cards: data.cards || [], drafts: data.drafts || [], limitations: data.limitations || [],
      }] });
    } catch (e) {
      if (e.name !== 'AbortError') {
        setError({ message: 'Connection interrupted. No answer was received; the server may still be finishing the request.' });
        onSessionChange({ ...session, messages });
        setInput(message);
      }
    } finally { setBusy(false); }
  };

  return (
    <div style={{ maxWidth: 980, margin: '0 auto', color: 'var(--color-text-primary)', display: 'grid', gap: 22 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', gap: 16, alignItems: 'start' }}>
        <div>
          <MicroLabel>Workspace assistant</MicroLabel>
          <h1 style={{ margin: '8px 0', fontSize: 30, fontWeight: 600, letterSpacing: '-0.035em' }}>Ask ActiveAgents</h1>
          <p style={{ margin: 0, color: 'var(--color-text-secondary)', fontSize: 14 }}>Find evaluation evidence. Understand failures. Build the next agent.</p>
        </div>
        {messages.length > 0 && <Button disabled={busy} onClick={() => { onSessionChange({ ...session, messages: [] }); setError(null); setInput(''); setAllowProviderProcessing(false); }}>New conversation</Button>}
      </div>

      {!messages.length && (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))', gap: 12 }}>
          {STARTERS.map(starter => (
            <button key={starter.label} onClick={() => { setInput(starter.message); formRef.current?.querySelector('textarea')?.focus(); }} style={{ textAlign: 'left', padding: 20, background: 'var(--color-card)', color: 'var(--color-text-primary)', border: '1px solid var(--color-border)', borderRadius: 12, cursor: 'pointer' }}>
              <div style={{ fontSize: 14, fontWeight: 600, marginBottom: 8 }}>{starter.label} ↗</div>
              <div style={{ fontSize: 12, lineHeight: 1.6, color: 'var(--color-text-secondary)' }}>{starter.message}</div>
            </button>
          ))}
        </div>
      )}

      <div role="log" aria-label="Assistant conversation" aria-live="polite" style={{ display: 'grid', gap: 20 }}>
        {messages.map((message, index) => (
          <div key={index} style={{ display: 'grid', gap: 12 }}>
            <MicroLabel color={message.role === 'user' ? 'var(--color-text-muted)' : 'var(--color-accent-ui)'}>{message.role === 'user' ? 'You' : 'ActiveAgents'}</MicroLabel>
            <div style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere', lineHeight: 1.7, fontSize: 14 }}>{message.content}</div>
            {message.cards?.map(card => <EvidenceCard key={card.id} card={card} onAsk={text => { setInput(text); formRef.current?.querySelector('textarea')?.focus(); }} busy={busy} />)}
            {message.drafts?.map(draft => <AgentDraft key={draft.id} draft={draft} onReview={onReviewDraft} />)}
            {message.limitations?.length > 0 && (
              <details style={muted}><summary style={{ cursor: 'pointer' }}>Scope of this answer</summary><ul style={{ paddingLeft: 18 }}>{message.limitations.map((item, i) => <li key={i}>{item}</li>)}</ul></details>
            )}
          </div>
        ))}
        {busy && <div role="status" style={{ color: 'var(--color-text-secondary)', fontSize: 13 }}>Working with your workspace evidence…</div>}
      </div>

      {error && <Card padding={16} role="alert" style={{ borderColor: 'var(--color-warning)', display: 'grid', gap: 12 }}>
        <div style={{ fontSize: 14 }}>{error.message}</div>
        {error.setup && <Button onClick={onOpenSettings} style={{ justifySelf: 'start' }}>Configure provider →</Button>}
      </Card>}

      <Card padding={18}>
        <form ref={formRef} onSubmit={event => { event.preventDefault(); ask(input); }} style={{ display: 'grid', gap: 14 }}>
          <label htmlFor="assistant-question" style={{ fontSize: 13, fontWeight: 600 }}>What would you like to do?</label>
          <textarea id="assistant-question" placeholder="Ask about your evals, or describe an agent to build…" value={input} onChange={event => setInput(event.target.value)} maxLength={limit} rows={3} disabled={busy} style={{ ...field, resize: 'vertical', boxSizing: 'border-box' }} />
          <div style={{ display: 'flex', gap: 12, alignItems: 'end', flexWrap: 'wrap' }}>
            <label style={{ display: 'grid', gap: 5, fontSize: 11, flex: '1 1 140px' }}>Provider
              <select aria-label="Assistant provider" value={provider} disabled={busy || !configuration} onChange={event => {
                const next = configuration.providers.find(item => item.id === event.target.value);
                setAllowProviderProcessing(false);
                onSessionChange({ ...session, provider: next?.id || '', model: next?.default_model || '' });
              }} style={field}>
                <option value="">{configuration ? 'Choose a provider…' : 'Loading…'}</option>
                {configuration?.providers?.map(item => <option key={item.id} value={item.id}>{item.id}{item.configured ? '' : ' · setup needed'}</option>)}
              </select>
            </label>
            <label style={{ display: 'grid', gap: 5, fontSize: 11, flex: '2 1 200px' }}>Model
              <input aria-label="Assistant model" value={model} disabled={busy || !configuration} maxLength={160} onChange={event => { setAllowProviderProcessing(false); onSessionChange({ ...session, model: event.target.value }); }} style={field} />
            </label>
            <Button variant="primary" type="submit" disabled={busy || !configuration || !input.trim() || !model.trim() || !executionEnabled || !allowProviderProcessing}>{busy ? 'Working…' : 'Ask ActiveAgents →'}</Button>
          </div>
          <label style={{ display: 'flex', gap: 9, alignItems: 'start', fontSize: 12, lineHeight: 1.6, color: 'var(--color-text-secondary)' }}>
            <input type="checkbox" checked={allowProviderProcessing} disabled={busy || !configuration} onChange={event => setAllowProviderProcessing(event.target.checked)} style={{ marginTop: 4 }} />
            <span>Allow {provider || 'the selected provider'} / {model || 'model'} to process my messages, recent conversation history, and authorized evaluation report excerpts for this conversation.</span>
          </label>
          <div style={{ ...muted, lineHeight: 1.5 }}>
            {!executionEnabled ? 'Agent execution is disabled on this dashboard.' : configuredProvider && !configuredProvider.configured ? 'This provider needs a credential in Settings before the assistant can respond.' : 'Uses your configured model provider. Agent drafts are reviewed before saving.'}
            {' '}Reloading or starting a new conversation clears this conversation view. Your provider's data retention settings still apply.
          </div>
        </form>
      </Card>
    </div>
  );
}
