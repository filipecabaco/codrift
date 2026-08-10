---
name: codrift-profiles
description: Use when setting up or debugging Codrift launch profiles — running the same agent CLI under two accounts, pointing an adapter at a wrapper script, passing extra args like --model, or choosing which agent an initiative launches. Triggers on "launch profile", "claude-work", "claude-personal", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "two accounts", "default_agent", "settings.json", "command not found in PATH" when creating a profile, or "which agent does this initiative use".
---

# Codrift launch profiles

A **launch profile** is a named agent: a base adapter, optionally its own
executable and extra arguments, plus environment overrides. It is how you run
`claude` under a work account and a personal account from the same app, or point
an adapter at a wrapper script, or pin `--model opus`.

Profiles apply only to that agent's spawned process. They set things like
`CLAUDE_CONFIG_DIR` — **not** `HOME` — so your shell, git and ssh config are
untouched.

## Defining one

In the app: the badge icon in the header, the gear beside the **Agent**
dropdown, `manage profiles` in the New initiative overlay, or *Launch profiles*
in the command palette (`⌃P`). Edits write straight to
`~/.codrift/settings.json`.

By hand, a `"profiles"` object keyed by name:

```json
{
  "default_agent": "claude-work",
  "profiles": {
    "claude-work": {
      "adapter": "claude",
      "command": "claude-work",
      "env": { "CLAUDE_CONFIG_DIR": "~/.claude-work" }
    },
    "claude-personal": {
      "adapter": "claude",
      "env": { "CLAUDE_CONFIG_DIR": "~/.claude-personal" }
    },
    "codex-work": {
      "adapter": "codex",
      "env": { "CODEX_HOME": "~/.codex-work" }
    }
  }
}
```

| Field | Meaning |
|---|---|
| `adapter` | The base tool (`claude`, `codex`, `opencode`, `gemini`, `copilot`). Decides argument handling, session resume and status parsing. |
| `command` | Optional. Executable to run instead of the adapter's own. A bare name is looked up in `PATH`; anything with a `/` or leading `~` is a path. |
| `args` | Optional. Appended to the adapter's own args. **One entry per argument** — `["--model", "opus"]` is two entries; a value with spaces needs no quoting. |
| `env` | Merged into the agent's process. `~` values expand to absolute paths. Overrides the adapter's defaults. |

A profile **cannot be named after a base adapter**. The Agent dropdown lists
both and resolves by name, so a profile called `claude` would shadow the real
one.

## Log in once before using it

A fresh config dir has no credentials. Create it and complete the login before
selecting the profile:

```bash
CLAUDE_CONFIG_DIR=~/.claude-work claude
```

From then on that folder holds that account's credentials and sessions.

## "command not found in PATH"

The profile form resolves `command` when you save, so a typo is rejected there
rather than surfacing later as a terminal that dies on open. If a name you can
run in your shell is rejected here, the app's `PATH` is the difference — a GUI
app launched from Finder inherits launchd's minimal `PATH`, not your shell's.
Either give the absolute path, or check that the shell function you are naming
is actually an executable on disk: **a shell function or alias defined in
`.zshrc` is not a command**, and `command` needs a real file.

## Choosing which agent an initiative runs

Each initiative has one agent, asked for up front:

- **At creation** — the Agent picker in the New initiative overlay (`n`). Your
  choice is stored on the initiative *and* becomes `default_agent`, so the next
  one starts from the same answer.
- **Afterwards** — the Agent dropdown in the Context view, for that initiative
  only.
- **Falling back** — initiative's agent → `default_agent` → plain `claude`.

Starting an agent (`s`, or the per-directory start button) uses that choice.
Running agents show their profile as a badge in the sidebar.

## From an agent

```
list_agent_profiles {}                                    # name + base adapter only
start_agent { initiative_id, dir, profile: "claude-work" }
```

`adapter` and `profile` passed to `start_agent` win over the initiative's
choice; omit both and the initiative's agent runs.

`list_agent_profiles` deliberately returns only names and adapters — profile
`env` never lands in an agent's context, so credentials and config paths stay
out of transcripts. Do not try to read `settings.json` to work around that.

Full reference: [docs/agent-profiles.md](https://github.com/filipecabaco/codrift/blob/main/docs/agent-profiles.md)
