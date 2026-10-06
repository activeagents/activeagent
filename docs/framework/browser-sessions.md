# Browser Sessions

A checkout sandbox (see [GitHub connections and checkout
sandboxes](./dashboard#github-connections-and-checkout-sandboxes)) can run a
browser of its own, pointed at the app the sandbox booted. Every agent run and
evaluation against that sandbox can drive it through Playwright MCP's tools,
and everything it shows is recorded into a session recording, so the session
can be replayed afterwards. A person can watch it live from the dashboard, and
take it over when the agent gets stuck.

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
| `ActionAgent.browser_live_origins` | `[]` | origins whose dashboard pages may open a browser's live view, besides the one it was started from (see [Watching live and taking over](#watching-live-and-taking-over)) |

## Starting and stopping a browser

| Request | Does |
|---|---|
| `POST /api/sandboxes/:id/browser` | starts the browser: `mode` (`"headless"`, the default, or `"headed"`) and optional `capabilities` |
| `GET /api/sandboxes/:id/browser` | shows it |
| `DELETE /api/sandboxes/:id/browser` | stops it |

Each answers `{ browser: { mode, status, started_at, server_key, live_url } }`.
The status is `starting`, `running`, `stopped` or `failed`. `server_key` is
`browser:<session_id>` while the browser runs, and `live_url` is its live
view's WebSocket while it runs and has one. A response never carries the
browser's MCP endpoint or its token. `GET /api/sandboxes` lists the modes a
browser can start in on the configured backend as `browser_modes`.

In the dashboard, a ready checkout sandbox under Settings → Integrations has
a Browser panel that starts and stops it, with "Open a window on this
machine" for `headed` where the backend can show one.

A project's browser, started for an [exploration](./dashboard#the-explorer-agent)
or a run of the project's evaluation, starts with the project's saved sign-in
(see [Signing in to the app](./dashboard#signing-in-to-the-app)), and the
sidecar's `GET /storage-state` hands a sign-in made in it back. Both are
limited to the cookies sent to the app's host and the localStorage of its
origin.

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

## Watching live and taking over

A browser started from the dashboard has a live view. Its Browser panel
offers "Watch live", which shows the page on screen as it changes, and
"Take over", which lets one person drive it with their own mouse and
keyboard until they press "Hand back".

- **What is shown.** The sidecar streams the page on screen with the Chrome
  DevTools Protocol's screencast, as JPEG frames. The view follows the tab
  the agent opened last or selected. A page that does not change sends no
  frames, so a viewer who joins sees the last one. Native dialogs, file
  pickers and other browser interface do not show (see [What the recording
  cannot show](#what-the-recording-cannot-show)).
- **One person drives.** While someone holds control, everyone else watching
  sees who ("Held by Ada"). Their clicks and scrolling on the view reach the
  page, and so do their keys while the view has keyboard focus. Pressing
  Escape twice, or clicking outside the view, moves keyboard focus away but
  keeps control: the agent goes on waiting until they press "Hand back" or
  "Stop watching". If their tab closes or loses its connection, control is
  released after 10 seconds. Until then the same person can pick it up from
  another tab, or after a reload, with "Continue driving here".
- **The agent waits.** While a person holds control, an agent's browser tool
  call that would change the page, such as `browser_click` or
  `browser_navigate`, waits for them to hand back, for up to 20 seconds. The
  live view shows a banner while it waits. If they have not handed back by
  then, the call returns an error naming them, and nothing is done; calls
  that only read the page, such as `browser_snapshot`, go ahead. The
  error's `_meta["activeagents/takeover"]` holds `{ held_by, since,
  waited_ms }`. A call still waiting when the browser stops returns an
  error saying the browser is stopping.
- **A window on this machine.** A `headed` browser on `:local` also has a
  real window. Clicking or typing in that window changes the page as well,
  but the agent does not wait for it: take over in the live view first.

### Tickets

The dashboard's page connects to the live view's WebSocket itself, with a
ticket it asks the dashboard for:

| Request | Does |
|---|---|
| `POST /api/sandboxes/:id/browser/tickets` | `mode: "view"` (the default) or `"control"`; answers `{ ticket, mode, expires_at, url }` |

- A view ticket needs only access to the sandbox. A control ticket also
  asks the permission checker about `:take_over_browser`, with the sandbox
  as the subject, and needs execution to be enabled. A denied control
  ticket answers 403.
- A browser that is not running, or has no live view, answers 409.
- A ticket lives 30 seconds and is accepted once. It names the sandbox, the
  user, their name (which other viewers see) and the mode, and is signed
  with a key derived from the browser's token, so it opens no other
  browser.
- The page asks for a view ticket to start watching, and for a control
  ticket each time the person presses "Take over". Withdrawing someone's
  `:take_over_browser` therefore stops them taking control again, though it
  does not take control from them while they hold it.
- The page sends the ticket as the WebSocket's first message, never in its
  URL. The sidecar closes a connection whose first message is not a valid
  ticket before sending it anything.

The WebSocket is opened from the dashboard's own page, so the sidecar
accepts it only from the origin the browser was started from and from
`ActionAgent.browser_live_origins`, and only through its own `Host`.

On `:local` the live view is a `ws://127.0.0.1:<port>` address, so only a
browser on the machine that runs the dashboard can open it.

- A host app whose Content Security Policy sets `connect-src` has to allow
  that address, for example `ws://127.0.0.1:*`, or the page's connection is
  blocked.
- A dashboard reached through an address other than a loopback one may need
  the browser's permission to connect to a loopback address. Chrome asks
  for it as local network access.

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
  URL less the query and fragment, and for each takeover starting and ending
  (`takeover_started`, `takeover_ended`, with `source: "human"`, who, and
  why it ended). What a person types while driving is never recorded or
  logged as such: their changes show in the masked rrweb events like the
  agent's.

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
- **A live view behind tickets.** The live view's WebSocket takes no token
  in its URL; a viewer proves who they are with a ticket in its first
  message (see [Tickets](#tickets)). It refuses an upgrade from any origin
  other than the dashboard's, through any `Host` but the sidecar's own, or
  with a query string. Only the person holding control has input relayed,
  and a viewer may send only pointer, wheel, key and text input, never a
  script or a DevTools command of its own.
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
| `live` | `{ session_id:, origins: }`: the live view's ticket subject and the dashboard origins that may open it, or nil for no live view |

`start_browser` returns `{ mcp_url:, mcp_token: }`, and a `live_url:`, the
WebSocket a viewer's page connects to, when `live` was given and the backend
can route a viewer to it. A backend that runs browsers as containers can run the sidecar's
OCI image, built from `browser-sidecar/Dockerfile` at the engine's version; it
reads the same settings as JSON on stdin or from a file (see the package's
README).
