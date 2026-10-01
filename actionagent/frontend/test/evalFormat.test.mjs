import assert from 'node:assert/strict';
import test from 'node:test';
import { COST_LEGEND, costTitle, fmtPasses, fmtPercent, fmtScore, fmtSpend, fmtThreshold } from '../utils/evalFormat.mjs';

test('a pass fraction carries its whole-number percentage, rounded half up', () => {
  assert.equal(fmtPasses(14, 16), '14/16 · 88%');
  assert.equal(fmtPasses(15, 32), '15/32 · 47%');
  assert.equal(fmtPasses(1, 16), '1/16 · 6%');
  assert.equal(fmtPasses(29, 200), '29/200 · 15%', '14.5% rounds up');
  assert.equal(fmtPasses(0, 5), '0/5 · 0%');
  assert.equal(fmtPasses(5, 5), '5/5 · 100%');
  assert.equal(fmtPasses(0, 0), '—');
  assert.equal(fmtPasses(null, null), '—');
});

test('a 0..1 score, percentage or threshold reads as a whole percent', () => {
  assert.equal(fmtPercent(0.875), '88%');
  assert.equal(fmtPercent(0.145), '15%', 'the decimal half, not the float below it');
  assert.equal(fmtPercent(0), '0%');
  assert.equal(fmtPercent(1), '100%');
  assert.equal(fmtPercent(null), '—');
  assert.equal(fmtPercent(undefined), '—');
  assert.equal(fmtScore(0.93), '93%');
  assert.equal(fmtScore(0.851), '85%');
  assert.equal(fmtScore(null), '—');
  assert.equal(fmtThreshold(0.7), 'pass ≥ 70%');
});

test('money has four decimals, six below a tenth of a cent, and marks an estimate', () => {
  assert.equal(fmtSpend(0.0243), '$0.0243');
  assert.equal(fmtSpend(0.0243, { estimated: true }), '~$0.0243');
  assert.equal(fmtSpend(0.000697, { estimated: true }), '~$0.000697');
  assert.equal(fmtSpend(0.6179), '$0.6179');
  assert.equal(fmtSpend(12.5), '$12.5000');
  assert.equal(fmtSpend(0), '$0.00');
  assert.equal(fmtSpend('0.0193'), '$0.0193');
  assert.equal(fmtSpend(null), '—');
  assert.equal(fmtSpend(null, { estimated: true }), '—');
  assert.equal(COST_LEGEND, '~ estimated from tokens × model rates');
});

test('an estimated figure explains itself in tokens × rates', () => {
  assert.equal(
    costTitle({ inputTokens: 2328, outputTokens: 423, rate: { input: 5, output: 30, source: 'catalog' } }),
    'estimated: 2,328 in × $5.00/M + 423 out × $30.00/M · catalog rate',
  );
  assert.equal(
    costTitle({ inputTokens: 1200, outputTokens: 80, rate: { input: 0.075, output: 0.3, source: 'remote' } }),
    'estimated: 1,200 in × $0.075/M + 80 out × $0.30/M · remote rate',
  );
  assert.equal(
    costTitle({ inputTokens: 10, outputTokens: 2, rate: { input: 3, output: 15, source: 'pattern' } }),
    'estimated: 10 in × $3.00/M + 2 out × $15.00/M · pattern rate (fallback rate)',
  );
  assert.match(costTitle({ inputTokens: 1, outputTokens: 1, rate: { input: 1, output: 2, source: 'default' } }), /\(fallback rate\)$/);
  assert.equal(costTitle({ inputTokens: 10 }), 'estimated from tokens × model rates');
  assert.equal(costTitle(), 'estimated from tokens × model rates');
});
