/**
 * Reads an Action Cable message from the engine. A message says only that a
 * record changed, as `{ type, id, status }`; a view that wants the record
 * reads it back over the JSON API. Anything else in the message is dropped,
 * and a message without a `type` is not an update.
 *
 * @param {*} message
 * @returns {{ type: string, id: (string|number|null), status: (string|null) } | null}
 */
export function liveUpdate(message) {
  if (!message || typeof message !== 'object' || typeof message.type !== 'string') return null;

  return { type: message.type, id: message.id ?? null, status: message.status ?? null };
}
