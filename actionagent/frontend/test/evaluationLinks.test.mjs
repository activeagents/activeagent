import assert from 'node:assert/strict';
import test from 'node:test';
import { evaluationLinkFromPath, evaluationLinkPath, shareableUrl } from '../utils/evaluationLinks.mjs';

test('reads an evaluation, a run and a scenario result from the path', () => {
  assert.deepEqual(evaluationLinkFromPath('/evaluations/3'), { evaluationId: 3, runId: null, resultId: null });
  assert.deepEqual(evaluationLinkFromPath('/evaluations/3/'), { evaluationId: 3, runId: null, resultId: null });
  assert.deepEqual(evaluationLinkFromPath('/evaluations/3/runs/12'), { evaluationId: 3, runId: 12, resultId: null });
  assert.deepEqual(evaluationLinkFromPath('/evaluations/3/runs/12/results/40'), { evaluationId: 3, runId: 12, resultId: 40 });
});

test('leaves other evaluation paths to their own routes', () => {
  for (const path of ['/evaluations', '/evaluations/3/runs/12/report', '/evaluations/0', '/evaluations/3/results/40',
    '/evaluations/abc', '/evaluations/3/runs/12/results/', '/traces/3', '', null]) {
    assert.equal(evaluationLinkFromPath(path), null, String(path));
  }
});

test('builds the path for each link shape and refuses incomplete ones', () => {
  assert.equal(evaluationLinkPath({ evaluationId: 3 }), '/evaluations/3');
  assert.equal(evaluationLinkPath({ evaluationId: 3, runId: 12 }), '/evaluations/3/runs/12');
  assert.equal(evaluationLinkPath({ evaluationId: 3, runId: 12, resultId: 40 }), '/evaluations/3/runs/12/results/40');
  assert.equal(evaluationLinkPath({ evaluationId: 3, resultId: 40 }), null, 'a result needs its run');
  assert.equal(evaluationLinkPath({ runId: 12 }), null);
  assert.equal(evaluationLinkPath({ evaluationId: 0 }), null);
  assert.equal(evaluationLinkPath({ evaluationId: 3, runId: 'x' }), null);
  assert.equal(evaluationLinkPath(), null);
});

test('a built path reads back as the same link', () => {
  const link = { evaluationId: 7, runId: 8, resultId: 9 };
  assert.deepEqual(evaluationLinkFromPath(evaluationLinkPath(link)), link);
});

test('the shared URL carries the origin and the mount', () => {
  assert.equal(shareableUrl('/evaluations/3', { origin: 'https://app.example.com', mountPath: '/activeagents/' }),
    'https://app.example.com/activeagents/evaluations/3');
  assert.equal(shareableUrl('/evaluations/3', { origin: 'https://app.example.com', mountPath: '/' }),
    'https://app.example.com/evaluations/3');
  assert.equal(shareableUrl(null, { origin: 'https://app.example.com' }), null);
});
