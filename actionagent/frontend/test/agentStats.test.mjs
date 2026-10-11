import assert from 'node:assert/strict';
import test from 'node:test';
import { activityTone, evalTone, fmtAgentCost, fmtDuration, fmtErrorRate, fmtLastSeen, fmtRuns } from '../utils/agentStats.mjs';

test('a run count groups its thousands and reads 0 when nothing ran', () => {
  assert.equal(fmtRuns(1284), '1,284');
  assert.equal(fmtRuns(48), '48');
  assert.equal(fmtRuns(0), '0');
  assert.equal(fmtRuns('4920'), '4,920');
  assert.equal(fmtRuns(null), '0');
  assert.equal(fmtRuns(undefined), '0');
});

test('a success rate reads as its error rate with one decimal', () => {
  assert.equal(fmtErrorRate(99.6), '0.4%');
  assert.equal(fmtErrorRate(97.1), '2.9%');
  assert.equal(fmtErrorRate(91.7), '8.3%');
  assert.equal(fmtErrorRate(100), '0.0%');
  assert.equal(fmtErrorRate(0), '100.0%');
  assert.equal(fmtErrorRate(99.95), '0.1%', 'the decimal half, not the float below it');
  assert.equal(fmtErrorRate(null), '—');
  assert.equal(fmtErrorRate(undefined), '—');
  assert.equal(fmtErrorRate(''), '—');
});

test('a duration is milliseconds under a second and seconds with one decimal above', () => {
  assert.equal(fmtDuration(410), '410ms');
  assert.equal(fmtDuration(999.6), '1000ms');
  assert.equal(fmtDuration(1800), '1.8s');
  assert.equal(fmtDuration(24100), '24.1s');
  assert.equal(fmtDuration(0), '0ms');
  assert.equal(fmtDuration(null), '—');
  assert.equal(fmtDuration(undefined), '—');
});

test('a cost has two decimals, marks a sub-cent amount, and is a dash when nothing priceable ran', () => {
  assert.equal(fmtAgentCost(12.4), '$12.40');
  assert.equal(fmtAgentCost(0.96), '$0.96');
  assert.equal(fmtAgentCost(0.004), '<$0.01');
  assert.equal(fmtAgentCost(0), '$0.00');
  assert.equal(fmtAgentCost('3.12'), '$3.12');
  assert.equal(fmtAgentCost(null), '—');
  assert.equal(fmtAgentCost(undefined), '—');
});

test('a last-seen time is relative up to a month, then a date, and never without one', () => {
  const now = Date.UTC(2026, 9, 10, 12, 0, 0);
  const ago = (seconds) => new Date(now - seconds * 1000).toISOString();
  assert.equal(fmtLastSeen(ago(0), now), 'just now');
  assert.equal(fmtLastSeen(ago(59), now), 'just now');
  assert.equal(fmtLastSeen(ago(60), now), '1m ago');
  assert.equal(fmtLastSeen(ago(14 * 60 + 30), now), '14m ago');
  assert.equal(fmtLastSeen(ago(3 * 3600), now), '3h ago');
  assert.equal(fmtLastSeen(ago(23 * 3600 + 3599), now), '23h ago');
  assert.equal(fmtLastSeen(ago(24 * 3600), now), '1d ago');
  assert.equal(fmtLastSeen(ago(29 * 86400), now), '29d ago');
  const date = fmtLastSeen(ago(30 * 86400), now);
  assert.doesNotMatch(date, /ago|never|just now/);
  assert.match(date, /2026/);
  assert.equal(fmtLastSeen(ago(-120), now), 'just now', 'a clock ahead of ours is not the future');
  assert.equal(fmtLastSeen(null, now), 'never');
  assert.equal(fmtLastSeen(undefined, now), 'never');
  assert.equal(fmtLastSeen('', now), 'never');
  assert.equal(fmtLastSeen('not a date', now), 'never');
});

test('a score is toned at 0.85 and 0.7, and muted without one', () => {
  assert.equal(evalTone(0.94), 'success');
  assert.equal(evalTone(0.85), 'success');
  assert.equal(evalTone(0.849), 'warning');
  assert.equal(evalTone(0.7), 'warning');
  assert.equal(evalTone(0.699), 'error');
  assert.equal(evalTone(0), 'error');
  assert.equal(evalTone('0.91'), 'success');
  assert.equal(evalTone(null), 'muted');
  assert.equal(evalTone(undefined), 'muted');
});

test('the activity dot is muted without runs, warning under an 85% success rate, success otherwise', () => {
  assert.equal(activityTone({ runs: 0, success_rate: 100 }), 'muted');
  assert.equal(activityTone({ runs: null, success_rate: null }), 'muted');
  assert.equal(activityTone({}), 'muted');
  assert.equal(activityTone(), 'muted');
  assert.equal(activityTone({ runs: 1284, success_rate: 99.4 }), 'success');
  assert.equal(activityTone({ runs: 48, success_rate: 98 }), 'success');
  assert.equal(activityTone({ runs: 48, success_rate: 97.9 }), 'warning');
  assert.equal(activityTone({ runs: 48, success_rate: 91.7 }), 'warning');
  assert.equal(activityTone({ runs: 312, success_rate: 0 }), 'warning');
  assert.equal(activityTone({ runs: 12, success_rate: null }), 'success', 'runs with no scored outcome are activity, not a fault');
});
