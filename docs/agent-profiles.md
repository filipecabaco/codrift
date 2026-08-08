# Agent launch profiles

A **launch profile** is a named binding of a base adapter plus environment
overrides, so the same tool can run under different accounts or config folders —
for example `claude-personal` and `claude-work` pointing at separate
`CLAUDE_CONFIG_DIR`s (each with its own login, settings, and sessions).

Profiles are generic: any adapter + any env map. The env is applied only to that
agent's process at spawn time; your shell, git, and ssh config are untouched
(profiles set `CLAUDE_CONFIG_DIR`, not `HOME`).

## Defining profiles

In the app: open **Launch profiles** — the badge icon in the header, or
`Launch profiles` in the command palette (⌃P). **New profile** asks for a name,
a base adapter, and the environment variables to set; the suggested variable
follows the adapter you pick (`CLAUDE_CONFIG_DIR` for claude, `CODEX_HOME` for
codex). Editing writes straight to `~/.codrift/settings.json`, so the file and
the view are always the same thing.

By hand, it is a `"profiles"` object in `~/.codrift/settings.json`, keyed by
name:

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

- `adapter` — the base tool the profile launches (`claude`, `codex`, …). A
  profile can't be *named* after a base adapter: the Launch dropdown lists both
  and resolves by name, so `claude` as a profile name would shadow the real one.
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

`get_agent_profiles`, `save_agent_profile` and `delete_agent_profile` are the
operations behind the view (`Codrift.Core`); they read and write the `profiles`
key through `Codrift.Config.Settings`. They are UI operations, not MCP tools —
`list_agent_profiles` (name + adapter only) is what agents see, so profile env
never lands in an agent's context by default.

At spawn, Codrift resolves the profile's base adapter, expands its env, and
injects it into the agent's process (`process.ex`, merged so profile env wins).
For Claude, the profile's `CLAUDE_CONFIG_DIR` is also threaded into session-file
detection so `--resume` vs `--session-id` resolves under the right config dir.
