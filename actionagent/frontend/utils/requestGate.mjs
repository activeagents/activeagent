/**
 * Used to drop a response that no longer answers the newest request, such
 * as a further page of a list whose filters changed while it loaded.
 *
 * `next()` supersedes every earlier request and returns the check for the
 * new one. `latest()` returns the check for the newest request without
 * superseding it. A check is true until the next call to `next()`.
 *
 * @returns {{ next: () => (() => boolean), latest: () => (() => boolean) }}
 */
export function createRequestGate() {
  let generation = 0;
  const checkFor = (mine) => () => mine === generation;

  return {
    next: () => checkFor(++generation),
    latest: () => checkFor(generation),
  };
}
