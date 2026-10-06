/**
 * Reads the owner's telemetry key from GET /api/telemetry_key. The dashboard
 * page does not carry it, so a view asks for it when it is to be shown or
 * copied.
 *
 * @param {(path: string, init?: object) => Promise<Response>} [request]
 * @returns {Promise<string|null>} the key, or null when the owner has none
 * @throws {Error} when the request fails
 */
export async function fetchTelemetryKey(request = fetch) {
  const response = await request('/api/telemetry_key', { cache: 'no-store' });
  if (!response.ok) throw new Error(`Could not load the telemetry key (HTTP ${response.status})`);

  const data = await response.json().catch(() => null);
  return data?.telemetry_api_key || null;
}
