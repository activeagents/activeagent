# Snag: the issue tracker demo

A small Rails app for showing Active Agent end to end: an ordinary CRUD app
gets an agent, the agent's work shows up as traces, and the conversations
people have with it become an evaluation suite that catches a real gap.

Everything in it is fictional: the team, the backlog, the shop.

- **The app** is a plain issue tracker: issues, comments, filters. No AI.
- **The agent is not in this repository.** You build it by hand in the
  dashboard at `/activeagents` and switch on tools this app declares.
- **The tools** are in `app/agent_tools/`: reading issues and people, and,
  granted separately, changing issues.
- **The chat panel** in the tracker runs that agent for the signed-in
  teammate (`app/models/assistant.rb`,
  `app/controllers/assistant_messages_controller.rb`).

## Setup

```bash
cd demo/issue_tracker
bundle install
bin/rails db:prepare            # creates the database and seeds the backlog
cp .env.example .env        # add ANTHROPIC_API_KEY
bin/rails server
```

Open <http://localhost:3000>. The tracker works straight away; the chat
panel says there is no agent yet.

No key to hand? `bin/rehearse` runs the same app against a scripted stand-in
for the model (`script/rehearsal_provider.rb`), with no network. It answers
the prompts below and a few like them, and it is what every step of this
runbook was checked against. It is a script, not a model, so rehearse with a
real key too: a model will phrase things differently and may take another
route through the tools.

## The demo, in three parts

### 1. The app, then an agent for it (about 6 minutes)

1. Show the tracker: the list, a filter, an issue, a comment. Point out #1
   and #2 (the same gift card crash, reported twice) and #14 (high priority,
   nobody on it).
2. Show `app/agent_tools/issue_tools.rb`: one model, the columns an agent may
   filter on and read back, and one hand-written `search_issues`.
3. Open **Agents ↗**, then **New Agent**.
   - Name: `Issue Agent`. The chat panel looks for that name, and an agent
     named after a model starts with that model's read tools.
   - Provider: Anthropic. Model: a fast one, such as `claude-haiku-4-5`.
4. **Configure.** The builder starts on the Terminal preset, so switch off
   **Terminal**, **Code** and the **GitHub** instructions. Switch on
   `find_issues`, `count_issues`, `get_issue`, `search_issues` and
   `find_users`. Leave `create_issue`, `update_issue` and `add_comment` off:
   that is the point of part 3.
5. Paste `docs/issue_agent_instructions.md` into **System Instructions**,
   continue, **Create Agent**.
6. Back in the tracker, reload. The panel is there. Ask, in this order:
   - `What's urgent right now?`
   - `Is there already an issue about gift cards?`
   - `Assign #14 to whoever owns auth`
   - `How many open issues are there?`

   The third one is the beat: the agent finds the owner, then says it has no
   tool for changing issues.

### 2. What it did (about 4 minutes)

1. **Traces**: one row per message. Expand the "Assign #14" trace: the prompt
   span, the model call, `tool.find_users` with its input and output, tokens
   and cost.
2. **Interactions**: the same four turns as a conversation.
3. Optional: **Run Agents** runs the same agent from the dashboard, with the
   conversation editable.

### 3. Evaluate it on what people asked (about 6 minutes)

1. In a terminal:

   ```bash
   bin/rails snag:evals:from_conversations
   ```

   Every message someone sent the agent becomes a scenario in an evaluation
   called *Real conversations*. Where the agent answered by calling tools,
   those tools are the scenario's expectation
   (`app/models/conversation_scenarios.rb`).
2. **Evaluations** → *Real conversations* → **Run 4 scenarios**. Each scenario
   is replayed through the agent and judged.
3. Three of four pass. Open the failure and **What to fix**: the agent was
   asked to change an issue and has no tool that can.
4. **Agents** → *Issue Agent* → the **Tools** tab. Click the `update_issue`
   row to switch it on, then **Save Changes**. (The Approval column on the
   same row is where a tool can be held for a person to approve each call.)
5. **Run 4 scenarios** again: four of four, `+1 passed` against the previous
   run, marked as a new version of the agent. In the tracker, #14 now belongs to Sofia, with a *via agent* comment
   saying why.
6. If there is time and a second key: type another model into the models
   field (`gpt-4o-mini`) and run once more to compare the two.

A replay is a real run: scenario 3 really assigns #14. Reset before the next
rehearsal.

## Between rehearsals

| Command | What it does |
|---|---|
| `bin/rails snag:reset` | Puts people, issues and comments back to the seeded backlog. Dashboard data is kept |
| `bin/rails snag:forget` | Clears everything the dashboard recorded: agents, conversations, traces, evaluations |
| `bin/rails snag:agent` | Creates the Issue Agent as step 3 to 5 would, read-only. `WRITES=1` grants the tools that change issues |
| `bin/rails test` | The tools and the conversation-to-scenario conversion, tested without a model |

For a clean stage: `bin/rails snag:forget snag:reset`, then build the agent
live. If the builder misbehaves on the day, `bin/rails snag:agent` gets you
to step 6 in one command.

## Before the day

- Run the whole thing twice with the real key, on the machine and the model
  you will present with. Note how long each answer takes.
- Decide what you do if the venue network fails. `bin/rehearse` is the
  fallback; say on stage that it is scripted.
- The first evaluation run is the slowest step: four replays and their
  judging. Have something to say while it runs.
- Make the browser font bigger than feels reasonable.

## How it is wired

- `config/initializers/action_agent.rb` names the tool classes the agent
  editor offers, and keeps them off the dashboard's own MCP endpoint.
- `config/active_agent.yml` configures the providers and stores traces in
  this app's database, where the mounted dashboard reads them.
- The gems come from this checkout (`Gemfile`: `path: "../.."`). In your own
  app that is `gem "activeagent"` and `gem "actionagent"`, then
  `bin/rails generate active_agent:install` and
  `bin/rails generate action_agent:install`.
