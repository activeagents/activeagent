import assert from 'node:assert/strict';
import test from 'node:test';

import { MAX_TICKET_SECONDS, TicketVerifier, signTicket, ticketKey } from '../lib/live-ticket.mjs';

const TOKEN = 'browser-token-0123456789abcdef0123456789';
const SESSION = '7f9a2c1e-4b5d-4e6f-8a9b-0c1d2e3f4a5b';
const NOW = 1_790_000_000;

function verifier(token = TOKEN, now = NOW) {
  return new TicketVerifier({ key: ticketKey(token), sessionId: SESSION, now: () => now * 1000 });
}

function claims(overrides = {}) {
  return { v: 1, sid: SESSION, sub: '42', name: 'Ada', mode: 'view', iat: NOW, exp: NOW + 30, jti: 'jti-0123456789abcdef', ...overrides };
}

function ticket(overrides = {}, token = TOKEN) {
  return signTicket(ticketKey(token), claims(overrides));
}

test('accepts a ticket for this sandbox once', () => {
  const check = verifier();
  const issued = ticket({ mode: 'control' });

  assert.deepEqual(check.verify(issued), { claims: { sub: '42', name: 'Ada', mode: 'control', exp: NOW + 30 } });
  assert.deepEqual(check.verify(issued), { refusal: 'already used' });
});

test('accepts a ticket the dashboard issued', () => {
  // Issued by ActionAgent::BrowserLiveTicket for this token and session, at
  // NOW (see browser_live_ticket_test.rb, which checks the same string).
  const issued = 'eyJ2IjoxLCJzaWQiOiI3ZjlhMmMxZS00YjVkLTRlNmYtOGE5Yi0wYzFkMmUzZjRhNWIiLCJzdWIiOiI0MiIsIm5hbWUiOiJBZGEiLCJtb2RlIjoiY29udHJvbCIsImlhdCI6MTc5MDAwMDAwMCwiZXhwIjoxNzkwMDAwMDMwLCJqdGkiOiJqdGktMDEyMzQ1Njc4OWFiY2RlZiJ9.-RYb5JgaJwTpXeuDO5HUfjBe6UlLEvcY4W0ObBzHIWQ';

  assert.equal(verifier().verify(issued).claims?.mode, 'control');
});

test('refuses a ticket signed for another browser, or altered', () => {
  assert.deepEqual(verifier().verify(ticket({}, 'another-browser-token-0123456789abcdef')), { refusal: 'bad signature' });

  const [, signature] = ticket().split('.');
  const altered = `${Buffer.from(JSON.stringify(claims({ mode: 'control' }))).toString('base64url')}.${signature}`;
  assert.deepEqual(verifier().verify(altered), { refusal: 'bad signature' });
});

test('refuses a ticket for another sandbox, or with an unknown mode', () => {
  assert.deepEqual(verifier().verify(ticket({ sid: 'another-session' })), { refusal: 'another sandbox' });
  assert.deepEqual(verifier().verify(ticket({ mode: 'admin' })), { refusal: 'unknown mode' });
});

test('refuses an expired ticket, one issued for too long, and one issued in the future', () => {
  assert.deepEqual(verifier(TOKEN, NOW + 30).verify(ticket()), { refusal: 'expired' });
  assert.deepEqual(verifier().verify(ticket({ exp: NOW + MAX_TICKET_SECONDS + 1 })), { refusal: 'bad lifetime' });
  assert.deepEqual(verifier().verify(ticket({ exp: NOW })), { refusal: 'bad lifetime' });
  assert.deepEqual(verifier().verify(ticket({ iat: NOW + 10, exp: NOW + 40 })), { refusal: 'issued in the future' });
  assert.ok(verifier().verify(ticket({ iat: NOW + 4, exp: NOW + 34 })).claims, 'a few seconds of clock skew are allowed');
});

test('refuses what is not a ticket', () => {
  const check = verifier();
  for (const value of [undefined, null, 42, '', 'no-dot', 'a.b.c', `${'a'.repeat(3000)}.b`, { ticket: ticket() }]) {
    assert.deepEqual(check.verify(value), { refusal: 'malformed' }, JSON.stringify(value)?.slice(0, 40));
  }
  assert.deepEqual(check.verify(ticket({ v: 2 })), { refusal: 'malformed' });
  assert.deepEqual(check.verify(ticket({ jti: 'short' })), { refusal: 'malformed' });
  assert.deepEqual(check.verify(ticket({ sub: 42 })), { refusal: 'malformed' });
  assert.deepEqual(check.verify(signTicket(ticketKey(TOKEN), 'a string')), { refusal: 'malformed' });
});

test('a ticket without a signed-in user carries no names', () => {
  assert.deepEqual(verifier().verify(ticket({ sub: null, name: null })).claims, { sub: null, name: null, mode: 'view', exp: NOW + 30 });
});

test('forgets the tickets it has seen once they expire', () => {
  let now = NOW;
  const check = new TicketVerifier({ key: ticketKey(TOKEN), sessionId: SESSION, now: () => now * 1000 });
  check.verify(ticket({ jti: 'first-ticket-0123456' }));
  assert.equal(check.used.size, 1);

  now = NOW + 31;
  check.verify(ticket({ jti: 'second-ticket-012345', iat: now, exp: now + 30 }));
  assert.deepEqual([...check.used.keys()], ['second-ticket-012345']);
});
