# Browser Sessions

A checkout sandbox (see [GitHub connections and checkout
sandboxes](./dashboard#github-connections-and-checkout-sandboxes)) can run a
browser of its own, pointed at the app the sandbox booted. Every agent run and
evaluation against that sandbox can drive it through Playwright MCP's tools,
and everything it shows is recorded into a session recording, so the session
can be replayed afterwards.

One sandbox runs at most one browser. It belongs to that sandbox alone: it
opens only the sandbox's app, it starts with an empty profile, and it stops
when the sandbox does.

## Installing on the `:local` backend

The `:local` sandbox backend runs the browser as the
`@activeagents/browser-sidecar` npm package, which lives in this repository's
`browser-sidecar/` directory and is published at the engine's version. The
gem itself contains no Node code. Install the package and its Chromium once,
under the local sandbox root (`tmp/action_agent/sandboxes/.browser` by
default):

```bash
bin/rails action_agent:browser:install
bin/rails action_agent:browser:doctor
```

`install` needs Node.js 20 or later and npm. `doctor` checks Node, the
sidecar's version and Chromium, and prints the fix for whatever is missing:

```
[ok]      node: Node.js 22.11.0
[ok]      sidecar: Browser sidecar 1.8.1
[missing] chromium: Chromium is not installed (tmp/action_agent/sandboxes/.browser/browsers). Run bin/rails action_agent:browser:install
```

Starting a browser runs the same checks first and refuses with the same
message, so nothing is downloaded when a browser starts. A sidecar of another
version than the engine is refused too.

| Setting | Default | Meaning |
|---|---|---|
| `ActionAgent.node_command` | `"node"` | the Node.js the sidecar runs with |
| `ActionAgent.npm_command` | `"npm"` | the npm `install` uses |
| `ActionAgent.browser_start_timeout` | `60` | seconds to wait for a browser to start |
| `ActionAgent.browser_sidecar_path` | unset | a checkout of `browser-sidecar/` to run instead of the installed package; its version is not checked. For working on the sidecar |

## Starting and stopping a browser

| Request | Does |
|---|---|
| `POST /api/sandboxes/:id/browser` | starts the browser: `mode` (`"headless"`, the default, or `"headed"`) and optional `capabilities` |
| `GET /api/sandboxes/:id/browser` | shows it |
| `DELETE /api/sandboxes/:id/browser` | stops it |

Each answers `{ browser: { mode, status, started_at, server_key, live_url } }`.
The status is `starting`, `running`, `stopped` or `failed`. `server_key` is
`browser:<session_id>` while the browser runs. A response never carries the
browser's MCP endpoint or its token.

A browser starts only for a checkout sandbox that is ready. A start is
refused with 422 while another browser of the same sandbox is starting or
running, for an unknown mode or capability, and on a backend that cannot run
a browser. Starting needs execution to be enabled, and asks the quota checker
about `:browser_minutes` (see [Metering](#metering)).

`capabilities` turns on optional groups of Playwright MCP tools: `testing`
(assertions such as `browser_verify_text_visible`), `vision` (clicks and drags
at coordinates) and `pdf`. Without them a browser offers Playwright MCP's
core tools: navigating, accessibility snapshots, clicking, typing, filling
forms, selecting, hovering, dragging, file uploads, dialogs, tabs, waiting,
screenshots, and console and network listings.

### The two modes

`headless` runs Chromium without a window. `headed` is for a person to watch:
on `:local` it opens a real Chromium window on the developer's machine, with
the same fresh profile, never the developer's own Chrome profile. `:local`
offers `headed` only where there is a display: on macOS, and on Linux with
`DISPLAY` or `WAYLAND_DISPLAY` set. A backend that cannot show a window
refuses a `headed` start with a message rather than starting a headless one.

## What an agent gets

While the browser runs, a run against its sandbox (`sandbox_id` on
`POST /api/agents/:id/execute` or `/test`, or on an evaluation run) reaches it
as the MCP server `browser:<session_id>`, beside the sandbox's own runtime.
The agent itself is not edited, and only a run against the sandbox reaches
it: a `browser:` key saved in an agent's `mcp_servers` reaches nothing.

- The browser's tools are offered from the browser alone. The dashboard's
  own `playwright_mcp` tools (`browser_navigate`, `browser_snapshot`,
  `browser_click`) have the same names, so they are left out of that run,
  and every `browser_*` name is offered once.
- A run records whether the browser was running when it was created. One
  whose browser stopped before it executes fails before the model is called,
  with `MCPToolDispatcher::SandboxUnavailable`.
- A page snapshot an action produces comes back inline with the tool's
  result.
- An agent's browser tool calls are recorded on its run's recording as
  `action` events, with typed values masked (see [Session
  timelines](./dashboard#session-timelines)).

In a multi-tenant install (`ActionAgent.multi_tenant = true`), the
`playwright_mcp` toolbox group, which drives one browser shared by the whole
process, is neither offered nor called: a run gets a browser only from its
sandbox.

## Recording

Each browser opens a `SessionRecording` of its own for the sandbox
(`source: "agent"`), which completes when the browser stops. The browser
posts to it, through the recording's ingest token:

- `rrweb` events from every page and frame, recorded with `@rrweb/record`.
  Input values, and the text of `contenteditable` elements such as rich-text
  editors, are masked in the page before an event leaves it, so typed values
  and passwords are stored as `*`.
- `console` events for errors and warnings.
- `marker` events for each page opening, navigating and closing, with its
  URL less the query and fragment.

The events reach the sidecar through a Playwright binding rather than a
request from the page, so the app's Content Security Policy and CORS rules do
not stop them, and the sidecar posts them gzipped in batches the size the
ingest accepts.

The recording takes events only while its sandbox is live. Deleting the
sandbox therefore stops its browser before the sandbox expires, and a browser
left to run stops itself 30 seconds before its sandbox's expiry, so the last
events reach the recording either way.

### What the recording cannot show

The recording is the page's DOM, as rrweb captures it. It does not show:

- the browser's own interface: the address bar, tabs, native dialogs
  (`alert`, `confirm`, file pickers, print, permission prompts) and downloads;
- canvas and WebGL drawing, video and audio;
- extensions, which the browser does not have.

## Metering

Starting a browser asks the quota checker about `:browser_minutes`, and a
denial answers 402 with the checker's payload. When the browser stops,
whether through `DELETE`, the sandbox's own `DELETE`, its expiry or
`action_agent:sandbox:reap`, the usage recorder is told the minutes it ran,
rounded up, as a third argument. The minutes are counted to when the browser
stopped itself at the latest, however late the reaper runs. In a multi-tenant
install both are asked about the tenant (the sandbox's account), the owner a
request's quota is checked against.

```ruby
ActionAgent.configure do |config|
  config.quota_checker = ->(owner, kind) { "No browser minutes left" if kind == :browser_minutes && owner.out_of_minutes? }
  config.usage_recorder = ->(owner, kind, quantity = nil) { owner.meter(kind, quantity || 1) }
end
```

A recorder that takes two arguments is still called as `(owner, kind)`. A
browser never outlives its sandbox: the sidecar stops itself 30 seconds
before the sandbox expires, and the reaper stops it when the sandbox expires.
A browser is not started for a sandbox that expires within those 30 seconds.

## Security

- **One browser per sandbox, with a new profile.** Chromium starts with an
  empty temporary profile that is deleted when it stops. Chromium's own
  sandbox stays on.
- **No debugging port.** Playwright drives Chromium over a pipe
  (`--remote-debugging-pipe`), so nothing listens that a page or another
  process could attach to.
- **A token on every request.** The sidecar's MCP endpoint answers only a
  request carrying `Authorization: Bearer <browser token>`. The token is
  generated per start, handed to the sidecar on stdin (never in its command
  line or its environment, and never to the sandboxed app), stored
  encrypted like the runtime token when `ActionAgent.encrypt_credentials` is
  on, never serialized or returned by the API, and masked out of recordings
  and MCP tool output.
- **Host and Origin checks.** The sidecar refuses a request, or a WebSocket
  upgrade, whose `Host` is not its own address, and any request carrying an
  `Origin` header. A page the browser visits therefore cannot reach the
  sidecar, through a loopback request or DNS rebinding.
- **No private addresses.** Chromium makes every HTTP, HTTPS and WebSocket
  connection, loopback included, through a proxy inside the sidecar, and
  WebRTC may not send UDP around it. The proxy resolves the host itself,
  refuses one that is a loopback, link-local or private address, or that
  resolves to one, and connects to the address it checked. The app's own
  host and port are the exception. This holds for every page and frame,
  after a redirect, and for a host name whose answer changes between two
  lookups. Service workers are blocked. Pages may still load public
  resources, such as fonts and scripts from a CDN.
- **Navigation pinned to the app.** A top-level navigation, from a tool or a
  link, may open only the sandbox app's origin; a path such as `/login` is
  resolved against it, and anywhere else is refused before anything loads.
  A redirect is followed without that check, so a tab that an HTTP redirect
  from an app page takes to another public origin is closed as soon as it
  lands there. The tool call that led there returns an error instead of its
  result, and the requests and console messages Playwright MCP collected
  from the tab go with it. Chromium has loaded the page by then, so its
  sandbox's recording can hold a moment of it.
- **No code in the sidecar.** Playwright MCP's `browser_run_code_unsafe`,
  which runs code in the sidecar's own process, is never offered or called,
  and pages cannot add tools of their own.
- **Uploads from the sidecar's own directories.** File uploads read only
  from a directory made empty for the session, and from the sidecar's output
  directory, which holds the snapshots, screenshots and console logs the
  browser's own tools wrote.

## For backend authors

A backend that runs browsers implements `start_browser(session, mode:)` and
`stop_browser(session)`, and optionally `browser_modes` (see [What a sandbox
backend implements](./dashboard#what-a-sandbox-backend-implements)).
`session.browser_launch` holds what a start needs beyond the session's
columns, for that call only:

| Key | Meaning |
|---|---|
| `token` | the bearer token the browser's MCP endpoint is to expect |
| `app_url` | the sandbox app, the only origin the browser may open |
| `capabilities` | the optional tool groups to enable |
| `stop_at` | when the browser is to stop on its own (`SandboxSession#browser_stops_at`, 30 seconds before the sandbox expires) |
| `recording` | `{ url:, token:, batch_events:, batch_bytes: }`: where to post recorded events, or nil |

`start_browser` returns `{ mcp_url:, mcp_token: }`, and optionally a
`live_url:`. A backend that runs browsers as containers can run the sidecar's
OCI image, built from `browser-sidecar/Dockerfile` at the engine's version; it
reads the same settings as JSON on stdin or from a file (see the package's
README).
