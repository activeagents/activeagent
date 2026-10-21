// Full-window chart counts and totals come from the server. Detail rows
// remain capped; associate only loaded rows with buckets for drill-down.
// Bucket traces for the throughput chart. Bucket width scales with the window
// so the chart stays readable at every zoom level.
const fallbackBuckets = (traces, agents, windowMinutes, bucketSeconds = 60) => {
  const now = Date.now();
  const data = [];
  const bucketMs = bucketSeconds * 1000;
  const bucketCount = Math.max(1, Math.round((windowMinutes * 60) / bucketSeconds));

  for (let i = bucketCount - 1; i >= 0; i--) {
    const bucketStart = now - (i + 1) * bucketMs;
    const bucketEnd = now - i * bucketMs;
    const bucketTraces = traces.filter(
      (t) => t.timestamp_ms >= bucketStart && t.timestamp_ms < bucketEnd
    );

    const durations = bucketTraces.map((trace) => trace.duration_ms).filter((value) => typeof value === 'number' && Number.isFinite(value));
    const agentBreakdown = {};
    agents.forEach((agent) => {
      agentBreakdown[agent] = bucketTraces.filter((t) => t.agent === agent).length;
    });

    data.push({
      // Past a day, the clock alone is ambiguous — show the date too.
      time: windowMinutes > 1440
        ? new Date(bucketEnd).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit' })
        : new Date(bucketEnd).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }),
      timestamp: bucketEnd,
      requests: bucketTraces.length,
      errors: bucketTraces.filter((t) => t.status === 'ERROR').length,
      avgLatency: durations.length > 0
        ? Math.round(durations.reduce((sum, value) => sum + value, 0) / durations.length)
        : 0,
      traces: bucketTraces,
      ...agentBreakdown,
    });
  }
  return data;
};


export const traceWindowData = (report, traces, agents, window) => {
  const buckets = Array.isArray(report?.buckets)
    ? report.buckets.map((bucket) => ({
      time: window.minutes > 1440
        ? new Date(bucket.end_ms).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit' })
        : new Date(bucket.end_ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }),
      timestamp: bucket.end_ms,
      requests: bucket.requests,
      errors: bucket.errors,
      avgLatency: bucket.avg_latency_ms,
      traces: traces.filter((trace) => trace.timestamp_ms >= bucket.start_ms && trace.timestamp_ms < bucket.end_ms),
      ...Object.fromEntries(agents.map((agent) => [agent, bucket.agents?.[agent] || 0])),
    }))
    : fallbackBuckets(traces, agents, window.minutes, window.bucketSeconds);
  // Compatibility with older host endpoints: average requests, not buckets.
  const durations = traces.map((trace) => trace.duration_ms).filter((value) => typeof value === 'number' && Number.isFinite(value));
  const summary = report?.summary ? {
    requests: report.summary.requests,
    errors: report.summary.errors,
    avgLatency: report.summary.avg_latency_ms,
    throughput: Number(report.summary.throughput_per_minute).toFixed(1),
  } : {
    requests: traces.length,
    errors: traces.filter((trace) => trace.status === 'ERROR').length,
    avgLatency: durations.length ? Math.round(durations.reduce((sum, value) => sum + value, 0) / durations.length) : 0,
    throughput: (traces.length / window.minutes).toFixed(1),
  };
  return { buckets, summary, truncated: report?.truncated === true, total: report?.total_count ?? traces.length };
};
