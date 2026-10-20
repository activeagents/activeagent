# @activeagents/browser-sidecar

One sandbox's browser for the Active Agent dashboard (the `actionagent` gem).
It launches Chromium with a fresh profile, serves Playwright MCP to the
agents run against the sandbox, and records every page with rrweb into the
sandbox's session recording.

The dashboard starts and stops it; you do not run it by hand. On the `:local`
sandbox backend, install it once with:

```bash
bin/rails action_agent:browser:install   # this package and its Chromium, under the local sandbox root
bin/rails action_agent:browser:doctor    # checks Node, this package's version and Chromium
```

Its version is always the engine's: the dashboard refuses a sidecar of any
other version.

## What it does

- **Browser.** Chromium through Playwright, headless or headed, with a new
  temporary profile directory that is removed when it stops. Playwright drives
  Chromium over a pipe (`--remote-debugging-pipe`), so no debugging port is
  ever opened, and Chromium's own sandbox stays on unless the configuration
  turns it off.
- **MCP.** Playwright MCP over HTTP at `POST /mcp`, one JSON-RPC message per
  request and a JSON response, with sessions named by `Mcp-Session-Id`. The
  tools are Playwright MCP's accessibility-snapshot tools, plus the optional
  groups `testing`, `vision` and `pdf` when the start configuration asks for
  them. `browser_run_code_unsafe`, which runs code in the sidecar's own
  process, is never offered. A page snapshot an action writes to a file is
  returned inline.
- **Network.** Chromium makes every connection through a forward proxy in
  the sidecar, loopback included, and WebRTC may not send UDP around it. The
  proxy resolves each host itself, refuses a loopback, link-local or private
  address, or a name that resolves to one, and connects to the address it
  checked. Only the app's own host and port are exempt. Redirects, frames
  and names whose answer changes between lookups all pass through it.
  Service workers are blocked.
- **Navigation.** A top-level navigation may only open the sandbox app's own
  origin; a path such as `/login` is resolved against it. Chromium follows a
  redirect without that check, so a tab a redirect takes to another origin
  is closed as soon as it lands, and the tool call that led there returns an
  error instead of its result.
- **Uploads.** Playwright MCP reads files to upload from the process's
  working directory, which is an empty directory made for the session, and
  from the sidecar's output directory, where its own snapshots, screenshots
  and console logs are written.
- **Recording.** `@rrweb/record` runs in every page and frame, injected with
  `addInitScript`, with input values and the text of `contenteditable`
  elements masked before an event leaves the page.
  Events reach the sidecar through a Playwright binding, so the app's CSP and
  CORS do not apply, and are posted, gzipped, to the recording's ingest with
  a token that can only write to that one recording. Console errors and
  warnings, and markers for pages opening, navigating and closing, go with
  them.
- **Live view.** With `live` in its configuration, the sidecar streams the
  page on screen to the dashboard over a WebSocket at `/live`, and relays the
  input of the one person who has taken control (see [The live
  view](#the-live-view)).

## The HTTP surface

| Request | Answer |
|---------|--------|
| `GET /health` | `{ "status": "ok", "version": "…" }` |
| `POST /mcp` | one JSON-RPC message, answered as JSON |
| `DELETE /mcp` | ends the session in `Mcp-Session-Id` |
| `GET /live` | the live view's WebSocket, when `live` is configured |
| `GET /storage-state` | `{ "storage_state": { "cookies": […], "origins": […] } }`: the browser's cookies and localStorage for the app, so a sign-in made in it can be kept |
| `POST /tokens` | `{ "label": "…" }` in, `{ "id", "token", "label", "expires_at" }` out: a client token for `/mcp` |
| `DELETE /tokens/:id` | revokes one |

Every request, a WebSocket upgrade other than the live view's included, must:

- carry `Authorization: Bearer <token>`, or, for `/mcp` only, a live client
  token;
- name an accepted `Host`: the listening address and port, the loopback names
  when listening on loopback or on every interface, and `allowed_hosts`;
- carry no `Origin` header. A page in a browser always sends one, so a page
  the browser visits cannot reach the sidecar, through a loopback request or
  DNS rebinding.

No CORS header is ever sent.

### Client tokens

A client that runs other people's code, such as Claude Code, whose shell
commands inherit its environment, should never hold the master token. The
dashboard mints it a client token for one turn (`POST /tokens`, with the
master token) and revokes it when the turn ends. A client token reaches
`/mcp` only, expires after six hours unless revoked first, and at most 32 are
live at once. Its `label` names the client wherever the live view shows it,
such as "Claude Code · turn 3 is waiting for control".

### Handoffs between an agent and a person

- When people took or handed back control since an MCP session's last tool
  call, its next result starts with a note saying who and when, and that the
  page may have changed, so the agent takes a snapshot before acting.
- With the live view on, the `browser_request_person` tool is offered: an
  agent asks the person watching to take over, with a reason. The sidecar
  answers it at once, and every viewer is sent
  `{ "type": "person_requested", "request": { reason, client, at } }`, also
  in `ready`, until someone takes control.

## The live view

The dashboard's page opens `ws://<host>:<port>/live` itself, so the upgrade
carries the dashboard's `Origin` and no token. It is accepted only when it
names an accepted `Host`, its `Origin` is one of `live.origins`, and its URL
has no query. The first message must then be a ticket:

```json
{ "type": "auth", "ticket": "<payload>.<signature>" }
```

The dashboard issues a ticket per viewer (`POST
/api/sandboxes/:id/browser/tickets`). Its payload is base64url JSON
`{ v: 1, sid, sub, name, mode, iat, exp, jti }`, and its signature is the
base64url HMAC-SHA256 of the payload under a key both sides derive from the
browser token: HMAC-SHA256 of `activeagents/browser-live-ticket/v1` keyed
with the token. The sidecar accepts a ticket once, for at most 60 seconds,
for this sandbox (`sid` is `live.session_id`) and for `mode` `view` or
`control`. A connection whose first message is anything else is closed
(code 4401) before anything is sent to it, and one that sends nothing for 5
seconds is closed with 4408.

Once accepted, the viewer is sent `ready`, the last frame, and every frame
after it: `{ type: "frame", data, width, height }`, a JPEG as base64 with the
page's size in CSS pixels. The stream follows the page on screen: the newest
tab, or the one the agent selected with `browser_tabs`. A still page sends no
frames, so the last one is kept for whoever joins later. `control`, `agent`
and `page` messages tell of who holds control, an agent call waiting for it,
and the page on screen. A `control` message's `mine` says whether this
connection holds control, and `yours` whether its user does on any
connection, as after a reload while control waits out the grace period.

Either mode of ticket lets a connection watch. To take control it sends
`{ type: "take_control", ticket }` with a control ticket of its own, issued
to the user it connected as, each time it asks. Withdrawing a person's
permission therefore stops them taking control again, but does not take it
from a connection that holds it. `{ type: "hand_back" }` gives control back.
One person holds control at a time; their other connections may move it
between them. While they hold it:

- their `mouse`, `wheel`, `key` and `text` messages reach the page through
  `Input.dispatchMouseEvent`, `Input.dispatchKeyEvent` and `Input.insertText`.
  Pointer positions are fractions of the frame, scaled to the page. Nobody
  else's input is relayed;
- an agent's tool call that would change the page waits for them to hand
  back, up to `live.agent_wait_ms`. If they have not, it returns an error
  naming them, with `_meta["activeagents/takeover"]`:
  `{ held_by, since, waited_ms }`. A call still waiting when the browser
  stops returns an error saying it is stopping. Calls that only read the
  page, such as `browser_snapshot`, go ahead;
- if their connection drops, control is released after
  `live.release_grace_ms`.

Relayed input is never logged or recorded. Taking control and handing it
back are recorded as `marker` events (`takeover_started`, `takeover_ended`,
with `source: "human"` and who), and what the person changed shows in the
masked rrweb stream.

### Uploading files

A page's `<input type="file">` opens a file chooser, which a headless browser
has no dialog for. When one opens while a person holds control, every viewer
is sent `{ type: "file_chooser", chooser: { id, multiple, accept, since,
max_files, max_file_bytes } }` (and `ready` carries it as `file_chooser` for
a viewer who joins), and only the person driving may answer it:

```json
{ "type": "file_upload", "chooser": "<id>", "files": [{ "name": "notes.txt", "size": 11 }] }
{ "type": "file_chunk", "chooser": "<id>", "data": "<base64, at most 32 KiB before encoding>" }
{ "type": "file_cancel", "chooser": "<id>" }
```

The chunks carry the files' bytes in the order they were listed, one file
running on into the next. Once the last byte arrives the files are set on the
input and the uploader is sent `{ type: "file_upload", chooser, status:
"done" }`; on the way, `"progress"` with `received` and `total` about every
MiB; and on a refusal, `"failed"` with a `code`: `not_driving`, `no_chooser`,
`too_many`, `too_large`, `bad_upload` or `upload_failed`. Everyone is then
sent `file_chooser` with `chooser: null`, as they are when the person cancels,
hands back control or lets five minutes pass without sending anything.

Each file is written, mode 0600, to a directory of its own under the
working directory, named by its last path segment without control or
reserved characters, and stays there until the browser stops, as the page
reads it from disk. `live.upload_max_file_bytes`, `live.upload_max_files`
(`0` turns uploads off) and `live.upload_max_session_bytes` bound it. File
names and contents are never logged or recorded; an upload is recorded as a
`file_uploaded` marker with its file count and size.

The sidecar listens for choosers only while someone holds control, as
Playwright intercepts them while anything listens: the rest of the time a
headed browser's own dialog opens, and an agent's chooser is left to
Playwright MCP's `browser_file_upload`. When someone takes control while an
agent's chooser waits there, it is offered to them. When the person answers a
chooser, or cancels one that opened while they drove, the modal state
Playwright MCP keeps for it is cleared too, so the agent's next call is not
refused for it. An agent's chooser the person leaves unanswered stays the
agent's.

## The command

```
activeagents-browser-sidecar serve [--config-file PATH]
activeagents-browser-sidecar check
activeagents-browser-sidecar install-browser [playwright install options]
activeagents-browser-sidecar --version
```

`serve` reads its configuration from stdin, or from `--config-file`, so the
token never appears in a process listing or an environment. Once it listens
it prints one line to stdout, `{"ready":true,"port":…,"version":"…","pid":…}`,
and logs only to stderr. SIGTERM, SIGINT or SIGHUP stops it: it closes the
browser, posts what it has recorded, and removes its directories.

`check` prints `{ "version", "node", "chromium": { "installed", "executable" } }`.
`install-browser` installs the Chromium this version drives, into
`PLAYWRIGHT_BROWSERS_PATH` when that is set.

## Configuration

```json
{
  "token": "…",
  "app_url": "http://127.0.0.1:3000",
  "mode": "headless",
  "capabilities": [],
  "host": "127.0.0.1",
  "port": 0,
  "allowed_hosts": [],
  "workdir": "/path/to/a/directory",
  "stop_at": 1767225600000,
  "chromium_sandbox": true,
  "recording": {
    "url": "http://127.0.0.1:3000/activeagents/api/session_recordings/7/events",
    "token": "aarec_…",
    "batch_events": 1000,
    "batch_bytes": 1048576
  },
  "live": {
    "session_id": "…",
    "origins": ["http://localhost:3000"],
    "agent_wait_ms": 20000,
    "release_grace_ms": 10000,
    "upload_max_file_bytes": 26214400,
    "upload_max_files": 10,
    "upload_max_session_bytes": 262144000
  },
  "storage_state": { "cookies": [], "origins": [] }
}
```

| Key | Meaning |
|-----|---------|
| `token` | the bearer token every request must carry (at least 32 characters) |
| `app_url` | the sandbox app; its origin is the only one a page may be opened on |
| `mode` | `headless`, or `headed` for a visible window |
| `capabilities` | optional Playwright MCP tool groups: `testing`, `vision`, `pdf` |
| `host`, `port` | where to listen; port `0` picks a free one |
| `allowed_hosts` | `Host` values to accept besides the listening address, such as a container name with its port |
| `workdir` | where the profile, uploads and output directories are made; a temporary directory when unset |
| `stop_at` | when to stop on its own, as epoch milliseconds or ISO 8601 |
| `chromium_sandbox` | `false` where Chromium's own sandbox cannot run, as in a container without the privileges it needs |
| `recording` | where to post recorded events, and the batch limits the ingest enforces; nothing is recorded when unset |
| `live` | the live view: the sandbox session tickets must name, the dashboard origins that may open it, how long an agent's call waits for control (at most 45000 ms), how long control outlives a dropped connection, and how much a person may upload (25 MiB a file, 10 files a chooser and 250 MiB in all by default; see [Uploading files](#uploading-files)); no live view when unset |
| `storage_state` | a Playwright storage state the browser starts with, such as a sign-in saved from `GET /storage-state`; only the cookies sent to the app's host and the localStorage of its origin are applied |

## The image

The `Dockerfile` here builds the same package with its Chromium, running as a
non-root user. A host that runs each sandbox's browser as a container starts
it with the configuration on stdin (`docker run -i`) or in a file:

```bash
docker run -i --rm -p 8931:8931 ghcr.io/activeagents/browser-sidecar:<version> < config.json
```

with `"host": "0.0.0.0"`, `"port": 8931`, and the name the dashboard reaches it
by in `allowed_hosts`.

## Developing

```bash
npm ci
npm test                                    # the real-browser test is skipped without Chromium
npx playwright install chromium && npm test # runs it too
```

To have the dashboard run a checkout of this directory instead of the
installed package, set `ActionAgent.browser_sidecar_path` to it. The version
check is skipped for a checkout.
