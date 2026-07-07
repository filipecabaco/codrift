# Agent launch profiles

A **launch profile** is a named binding of a base adapter plus environment
overrides, so the same tool can run under different accounts or config folders —
for example `claude-personal` and `claude-work` pointing at separate
`CLAUDE_CONFIG_DIR`s (each with its own login, settings, and sessions).

Profiles are generic: any adapter + any env map. The env is applied only to that
agent's process at spawn time; your shell, git, and ssh config are untouched
(profiles set `CLAUDE_CONFIG_DIR`, not `HOME`).

## Defining profiles

Add a `"profiles"` object to `~/.codrift/settings.json`, keyed by name:

```json
{
  "profiles": {
    "claude-work": {
      "adapter": "claude",
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

- `adapter` — the base tool the profile launches (`claude`, `codex`, …).
- `env` — environment variables merged into the agent's process. Values
  starting with `~` are expanded to absolute paths. These override the adapter's
  own defaults for the same key.

First-time setup for a Claude profile: create the config dir and log in under it,
e.g. `CLAUDE_CONFIG_DIR=~/.claude-work claude` and complete the login once. From
then on that folder holds that account's credentials and sessions.

## Using a profile

- **In the app:** the **Launch** dropdown (Context view) lists your base
  adapters and, under a **Profiles** group, every configured profile. Pick one
  and start an agent in a directory. Running agents show their profile as a
  badge in the sidebar.
- **From an agent / MCP:** call `start_agent` with an extra `profile` argument
  (the profile name). `list_agent_profiles` returns the available profiles.

## How it works

At spawn, Codrift resolves the profile's base adapter, expands its env, and
injects it into the agent's process (`process.ex`, merged so profile env wins).
For Claude, the profile's `CLAUDE_CONFIG_DIR` is also threaded into session-file
detection so `--resume` vs `--session-id` resolves under the right config dir.
