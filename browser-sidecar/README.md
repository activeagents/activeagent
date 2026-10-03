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
- **Navigation.** A top-level navigation may only open the sandbox app's own
  origin; a path such as `/login` is resolved against it. No request, from any
  page or frame, may reach a loopback, link-local or private address other
  than the app's, whether the URL names the address or a host name that
  resolves to one. Service workers are blocked so that every request passes
  this check.
- **Uploads.** Playwright MCP reads files to upload from the process's
  working directory, which is an empty directory made for the session.
- **Recording.** `@rrweb/record` runs in every page and frame, injected with
  `addInitScript`, with every input masked before an event leaves the page.
  Events reach the sidecar through a Playwright binding, so the app's CSP and
  CORS do not apply, and are posted, gzipped, to the recording's ingest with
  a token that can only write to that one recording. Console errors and
  warnings, and markers for pages opening, navigating and closing, go with
  them.

## The HTTP surface

| Request | Answer |
|---------|--------|
| `GET /health` | `{ "status": "ok", "version": "…" }` |
| `POST /mcp` | one JSON-RPC message, answered as JSON |
| `DELETE /mcp` | ends the session in `Mcp-Session-Id` |

Every request, a WebSocket upgrade included, must:

- carry `Authorization: Bearer <token>`;
- name an accepted `Host`: the listening address and port, the loopback names
  when listening on loopback or on every interface, and `allowed_hosts`;
- carry no `Origin` header. A page in a browser always sends one, so a page
  the browser visits cannot reach the sidecar, through a loopback request or
  DNS rebinding.

There is no WebSocket endpoint, and no CORS header is ever sent.

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
  }
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
