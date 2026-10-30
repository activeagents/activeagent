// Shareable links to evaluations. Three shapes, mount-relative:
//
//   /evaluations/:id                                 an evaluation, open
//   /evaluations/:id/runs/:run_id                    one of its runs, shown
//   /evaluations/:id/runs/:run_id/results/:result_id one scenario result of
//                                                    that run, its row open
//
// The server checks each against the caller's scope before rendering the
// page (DashboardController#evaluation), so a link only opens for members
// of the account that owns the evaluation.

const ID = '([1-9]\\d*)';
const LINK_PATH = new RegExp(`^/evaluations/${ID}(?:/runs/${ID}(?:/results/${ID})?)?/?$`);

// Returns { evaluationId, runId, resultId } (numbers; runId and resultId
// null when the path does not name them) for a mount-relative path, or null
// for any other path, the run report page included.
export function evaluationLinkFromPath(path) {
  const match = String(path || '').match(LINK_PATH);
  if (!match) return null;
  const id = (value) => (value ? Number(value) : null);
  return { evaluationId: Number(match[1]), runId: id(match[2]), resultId: id(match[3]) };
}

const positive = (value) => /^[1-9]\d*$/.test(String(value ?? ''));

// Returns the mount-relative path for an evaluation, a run or a result, or
// null when the ids do not make a link: a result needs its run, a run its
// evaluation.
export function evaluationLinkPath({ evaluationId, runId = null, resultId = null } = {}) {
  if (!positive(evaluationId)) return null;
  let path = `/evaluations/${evaluationId}`;
  if (runId == null) return resultId == null ? path : null;
  if (!positive(runId)) return null;
  path += `/runs/${runId}`;
  if (resultId == null) return path;
  return positive(resultId) ? `${path}/results/${resultId}` : null;
}

// Returns the absolute URL a mount-relative path is shared as: origin, then
// the engine's mount, then the path.
export function shareableUrl(path, { origin = '', mountPath = '' } = {}) {
  if (!path) return null;
  const mount = String(mountPath || '').replace(/\/+$/, '');
  return `${String(origin || '').replace(/\/+$/, '')}${mount}${path}`;
}
