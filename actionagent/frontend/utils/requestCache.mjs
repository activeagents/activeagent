/**
 * Returns a function that shares one call of `load(key)` per key: callers
 * asking while it is in flight get the same promise, and so do callers asking
 * within `ttlMs` of it resolving with a value `keep` accepts. A value `keep`
 * rejects, or a rejection, is not kept, so the next caller loads again.
 * `clear()` forgets every key.
 *
 * @param {(key: string) => Promise<*>} load
 * @param {Object} options
 * @param {number} options.ttlMs
 * @param {(value: *) => boolean} [options.keep]
 * @param {() => number} [options.now]
 * @returns {((key: string) => Promise<*>) & { clear: () => void }}
 */
export function createRequestCache(load, { ttlMs, keep = () => true, now = Date.now }) {
  const entries = new Map();

  const cached = (key) => {
    const entry = entries.get(key);
    if (entry && (entry.expiresAt === null || now() < entry.expiresAt)) return entry.promise;

    const next = { expiresAt: null };
    next.promise = load(key).then(
      (value) => {
        if (entries.get(key) === next) {
          if (keep(value)) next.expiresAt = now() + ttlMs;
          else entries.delete(key);
        }
        return value;
      },
      (error) => {
        if (entries.get(key) === next) entries.delete(key);
        throw error;
      },
    );
    entries.set(key, next);
    return next.promise;
  };

  cached.clear = () => entries.clear();
  return cached;
}
