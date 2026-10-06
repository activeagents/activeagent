---
title: "Demo: an agent registers for SF Ruby Conf, you pay"
description: Stage runbook for the conference-ticket handoff demo on the Active Agent dashboard.
---

# Demo: an agent registers for SF Ruby Conf, you pay

The agent drives the platform's browser from the event page to the ticket
checkout, enters the attendee details, and stops the moment the page asks
for payment. The dashboard shows where it stopped. You press **Take Over
Session**, the checkout opens in your own browser, and you pay on stage.

What the audience sees, in order:

1. **Run Agents**: the Conference Ticket Agent is given the event URL, a name,
   an email and the ticket to buy.
2. The live run: `browser_navigate`, `browser_snapshot`, `browser_click`
   rows appear as the agent finds the Tickets link, follows it to the
   ticketing page, picks the ticket, fills the attendee form.
3. A `request_handoff` row: *payment details*. The agent's reply says where
   it stopped and what it entered.
4. **Session Replay**: the run's recording, with a red **Handoff** line
   naming the checkout URL and the values entered, and a **Take Over
   Session** button.
5. You press it. The checkout opens in a new tab. You pay.
6. Back in the dashboard: the trace, with the browser tool calls, the model
   calls and their cost.

## What is in the box

- `request_handoff`, a tool every agent with the `playwright_mcp` tools has.
  It stores the current page URL and the non-secret values the agent
  entered on the run's session recording, and records a `handoff` action.
  Keys that look like a card number, password or code are dropped before
  anything is stored.
- Browser tool calls in such runs are recorded, so the run plays back in
  Session Replay.
- The **Conference Ticket Agent** template (Templates, slug
  `conference-ticket`): the instructions above, with hard rules. It never
  enters payment details, never clicks Pay or Complete registration, never
  accepts terms, never invents details.
- **Take Over Session** opens the handoff URL in a new tab and lists what
  was already entered.

## Before the day

### The browser

The dashboard's browser tools talk to a Playwright MCP server at
`PLAYWRIGHT_MCP_URL` (`ActionAgent::PlaywrightMCPClient`). Two ways to run
it for the demo:

- **Cloud browser**: the platform's sandbox backend, headless. The audience
  follows the run through the dashboard's live run view and Session Replay.
- **Headed on the demo machine**: the audience watches the browser itself.
  Start it before the talk and point the dashboard at it:

  ```bash
  npx @playwright/mcp@latest --port 8931
  PLAYWRIGHT_MCP_URL=http://localhost:8931/mcp bin/rails server
  ```

  Headed is the better stage picture. The browser window is the agent's; the
  checkout opens in your own browser on Take Over.

  The server answers only the host it was started for, `localhost` by
  default, and refuses any other `Host` header with a 403. Reaching it under
  another name (the platform's default is `host.orb.internal:8931`) needs
  `--allowed-hosts host.orb.internal:8931`, or `--allowed-hosts '*'` on a
  machine nobody else can reach.

Prove the plumbing on the machine you will present from:

```bash
PLAYWRIGHT_MCP_SMOKE=1 bin/test actionagent/test/playwright_mcp_smoke_test.rb
```

It starts the real Playwright MCP server, lists its tools, and drives a
static ticket page (`actionagent/test/fixtures/files/conference_tickets.html`)
with the same client the dashboard uses. Set `PLAYWRIGHT_CHROMIUM` to a
browser executable if Playwright has not installed one.

### The model

The template runs on Anthropic. Add the key under Settings → Provider API
Keys, or set `ANTHROPIC_API_KEY` for the dashboard process.

### The agent

Templates → Conference Ticket Agent → Use This Template. Name it for the
stage, for example *SF Ruby Ticket Agent*. Nothing else to configure.

### The sample data

A fresh workspace shows empty Traces and Evaluations until the live run.
Seed the scenario's sample first, so the dashboard has a week of history
to point at while the agent works:

```bash
bin/rails action_agent:sample:conference_ticket        # ACCOUNT_ID=<id> on the platform
bin/rails action_agent:sample:clear                    # when you want it gone
```

It creates a *Conference Ticket Agent (sample)* with seven runs and their
traces, a completed session recording that offers Take Over at the ticket
page, and the evaluation **Ticket run safety**: three scenarios, two runs.
The older run caught the agent clicking **Pay $500** in both registration
scenarios (fault: forbidden content, with the fix it called for: never
click Pay, hand off when a card field appears); the newer run, after that
rule, passes every scenario. That
is the pitch in two rows: the trace shows what the agent did, the
evaluation shows it being caught, and the fix is one sentence of
instructions. Everything in it is fictional and marked `sample`.

### A full rehearsal, the day before

Run it against the real event page once, end to end, and stop at the
handoff:

> Register me for the San Francisco Ruby Conference at https://sfruby.com.
> Attendee: [YOUR NAME], [YOUR EMAIL]. Ticket: Both days. Stop at payment.

Watch for two things:

- **Where the handoff lands.** SF Ruby sells tickets through Luma. Luma may
  ask for an email code before the attendee form, which is also a handoff:
  the agent stops there, you enter the code, and you finish the registration
  yourself. Either way the demo works; know which beat you will get.
- **The URL you land on.** Take Over opens the page URL the agent stopped on
  in your browser, not the agent's browser session. If the ticketing site
  keeps the cart in its session rather than the URL, you re-select the
  ticket there; the Handoff line in Session Replay shows what the agent
  entered so you can repeat it in seconds.

## On stage

Suggested prompt, typed live into Run Agents:

> Register me for the San Francisco Ruby Conference at https://sfruby.com.
> Attendee: [YOUR NAME], [YOUR EMAIL]. Ticket: Both days. Stop at payment.

Timing from experience with similar runs: forty to ninety seconds to the
handoff. While it runs, narrate the tool rows. When `request_handoff`
appears, read the agent's three-line report aloud, open Session Replay, and
take over.

Fallbacks:

- The venue network is slow: have the rehearsal run's recording open in a
  second tab. Session Replay plays it back, and Take Over works on it.
- The ticketing site changed: the agent reads the page, so most changes do
  not matter. If it stops early, its report says why; the fix is usually one
  more sentence in the prompt.
- Payment: it is your card in your browser, as it would be without the
  agent. Nothing about the card ever reaches the agent or the dashboard.

## Why the handoff is the demo

The agent does the part a person is slow at, and stops exactly at the part
only a person may do. Nothing in the run can pay, and the recording proves
what was entered. That is the shape of every agent that touches money.
