import React, { useState, useEffect } from 'react';
import { dashboardPath } from '../../utils/dashboardPath';

export default function AgentFeedbackTab({ agentId, colors }) {
  const [rating, setRating] = useState('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [page, setPage] = useState(1);
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);
  const [reload, setReload] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    setData(null); setError(null);
    const query = new URLSearchParams({ agent_id: agentId, rating, from, to, page });
    fetch(dashboardPath(`/api/feedback?${query}`), { signal: controller.signal })
      .then(async response => {
        if (!response.ok) throw new Error('Could not load feedback.');
        return response.json();
      }).then(setData).catch(err => { if (err.name !== 'AbortError') setError(err.message); });
    return () => controller.abort();
  }, [agentId, rating, from, to, page, reload]);
  const change = setter => event => { setter(event.target.value); setPage(1); };
  return <section aria-label="User feedback" style={{ color: colors.textPrimary, background: colors.cardBg, border: `1px solid ${colors.cardBorder}`, borderRadius: 12, padding: 20 }}>
    <div className="flex flex-wrap items-center gap-4 mb-4">
      <label>Rating <select value={rating} onChange={change(setRating)} style={{ color: colors.textPrimary, background: colors.cardBg }}>
        <option value="">All ratings</option><option value="positive">Thumbs up</option><option value="negative">Thumbs down</option>
      </select></label>
      <label>From <input type="date" value={from} onChange={change(setFrom)} style={{ color: colors.textPrimary, background: colors.cardBg }} /></label>
      <label>To <input type="date" value={to} onChange={change(setTo)} style={{ color: colors.textPrimary, background: colors.cardBg }} /></label>
      <button type="button" onClick={() => setReload(value => value + 1)}>Refresh</button>
    </div>
    {error && <p role="alert">{error}</p>}
    {!data && !error && <p role="status">Loading feedback…</p>}
    {data && <>
      <p className="mb-4">{data.positive} thumbs up · {data.negative} thumbs down · {data.positive_percentage == null ? 'No ratings' : `${data.positive_percentage}% positive`} ({data.total} ratings matching filters)</p>
      {data.total === 0 && <p>No feedback recorded for these filters. Submit feedback from your application after the trace is ingested.</p>}
      <ul>{data.feedback.map(item => <li key={item.id} className="py-4" style={{ borderTop: `1px solid ${colors.cardBorder}` }}>
        <strong>{item.rating === 'positive' ? '👍 Thumbs up' : '👎 Thumbs down'}</strong>
        <span> · {new Date(item.created_at).toLocaleString()}</span>
        {item.user_reference && <span> · {item.user_reference}</span>}
        {item.comment && <p style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{item.comment}</p>}
        <a className="underline" href={dashboardPath(`/traces?trace=${encodeURIComponent(item.trace_id)}`)}>Open interaction trace</a>
        {item.span_id && <p>Response span: <code>{item.span_id}</code></p>}
      </li>)}</ul>
      <div className="flex gap-4 mt-4">
        <button disabled={page === 1} onClick={() => setPage(value => value - 1)}>Previous</button>
        <span>Page {page}</span>
        <button disabled={page * 50 >= data.total} onClick={() => setPage(value => value + 1)}>Next</button>
      </div>
    </>}
  </section>;
}
