---
name: codrift-orchestration
description: Use when spawning, coordinating, or supervising other Codrift agents — fan-out across directories, orchestrator-led planning, broadcasting to every agent, or checking what siblings are doing. Triggers on "start an agent", "spawn agents", "fan out", "conductor", "orchestration", "orchestration.md", "broadcast", "run this across every repo", "what are the other agents doing", or "stop the agents".
---

# Codrift orchestration

Codrift can run many agents at once across an initiative's directories. There
are three ways to drive that, from least to most autonomous.

## 1. Start agents yourself

```
list_agent_profiles {}                                    # names + base adapters
start_agent { initiative_id, dir, adapter: "claude", profile: "claude-work" }
send_to_agent { agent_id, input: "run the test suite and report failures" }
get_agent_output { agent_id, n: 50 }
```

`adapter` is one of `claude`, `codex`, `opencode`, `gemini`, `copilot`, `cursor`.
`profile` is optional and names a launch profile from `settings.json` — it runs
the adapter under a different config folder/account (e.g. a personal vs work
Claude login). Omit `dir` for a folderless initiative and the agent runs in the
initiative's scratchpad folder.

Prefer this when you know exactly what needs to happen where.

## 2. Fan out — one agent per directory

```
start_conductor { initiative_id, adapter: "claude" }
```

Spawns one agent per working directory immediately, with no planning step. Right
for mechanically parallel work — "apply this same migration in every repo",
"upgrade the linter everywhere".

Wrong when the directories need different instructions, or when one repo's
outcome should change what happens in another. Use orchestration for that.

## 3. Orchestration — an agent that plans and delegates

```
update_orchestration_md { initiative_id, content: "..." }   # set intent FIRST
start_orchestration     { initiative_id, task: "migrate auth to JWT across api and web" }
```

One orchestrator agent reads `orchestration.md`, then plans, spawns and
coordinates sub-agents across directories using these same MCP tools.

**Write `orchestration.md` before starting.** It is the orchestrator's standing
brief, and an empty one produces an orchestrator that invents its own goal. Give
it a goal, a strategy, and success criteria:

```markdown
# Goal
Move authentication from server sessions to JWT across api/ and web/.

# Strategy
1. api/ lands the token issuer and verification middleware first.
2. web/ only starts once api/ exposes /auth/token — do not run them in parallel.
3. Neither repo removes the session code path until both sides pass tests.

# Success
- `mix test` green in api/, `pnpm test` green in web/
- No remaining references to `Plug.Session` outside the legacy fallback
```

Read it back with `read_orchestration_md { initiative_id }`.

`start_orchestration` also takes an optional `context_dir` to override the
default `~/.codrift/initiatives/{id}/`.

## Supervising a run

```
get_conductor_status  { initiative_id }   # agent ids, dirs, status, orchestrator vs worker
get_conductor_results { initiative_id }   # aggregated output, keyed by agent id
stop_orchestration    { initiative_id }   # kills orchestrator + every sub-agent
```

`stop_orchestration` returns `stopped: false` when nothing was running — that is
a normal answer, not an error.

## Broadcasting

```
broadcast_to_initiative { initiative_id, input: "the schema changed, re-read models.ex" }
```

This interrupts **every** running agent in the initiative. Use it for facts they
all must act on. Do not use it for status updates or questions — you will
derail several sessions at once to collect answers you could have read from
`get_agent_output`.

## Handing back to the human

Some steps are not yours to take. The user may reserve `git commit` and
`git push` for themselves, a deploy may need a human to approve it, a login may
need a password you must never see. Spawning another *agent* for those is the
wrong move — it just relocates the thing you are not allowed to do.

`open_terminal` puts a real shell in a Codrift pane and moves the user's
keyboard into it:

```
open_terminal {
  initiative_id,
  dir:     "/Users/me/code/api",
  command: "git commit -m \"add refresh-token rotation\"",
  reason:  "review the staged auth changes and commit"
}
```

`command` is **typed at the prompt but not run**. The user reads it and presses
Return themselves — that is the whole point, and it is what makes the tool safe
to reach for on exactly the steps you are forbidden from taking. Newlines in it
are flattened to spaces so nothing can submit itself; use repeated flags rather
than embedded newlines.

Then stop and wait. The tool returns as soon as the pane opens, which is *not*
the same as the command having run:

```
get_agent_output { agent_id }
```

Read it before you continue, and do not assume success. The user may edit your
command, run something else, or close the terminal without running anything.

To send them back to a terminal or agent you opened earlier — rather than
opening a second one — use `focus_agent { agent_id, reason }`.

If you have a shell but not these tools, the CLI does the same two things:

```bash
codrift pane terminal <initiative_id> --dir=/path \
  --command='git commit -m "…"' --reason='review and commit'
codrift pane focus <agent_id> --reason='back to you'
```

Missing tools usually means the MCP server was never registered for the config
directory *you* are running in — see `codrift mcp status` in `codrift-mcp`.

Two things to respect: this **takes the keyboard away from whatever they were
doing**, and `reason` is the only explanation they get for why. Ask once, ask
for something specific, and make the reason a sentence they can act on.

## Before you spawn anything

Check what is already running. Starting a second agent in a directory that
already has one is how two agents end up editing the same file.

```
get_initiative_agents { initiative_id }
list_agents {}
```

And check the combined diff — a sibling's uncommitted work is invisible to your
file reads and to `git log`:

```
get_diff { initiative_id }
```

## Cost

Every spawned agent is a full model session. Fan-out across six directories is
six times the spend. Match the mechanism to the work: one agent for one repo, a
conductor for genuinely parallel mechanical work, an orchestrator only when the
plan itself needs to be discovered.
