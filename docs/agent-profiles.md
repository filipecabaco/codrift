# Agent launch profiles

A **launch profile** is a named agent: a base adapter, optionally its own
executable and extra arguments, plus environment overrides — so the same tool
can run under different accounts or config folders. For example
`claude-personal` and `claude-work` pointing at separate `CLAUDE_CONFIG_DIR`s
(each with its own login, settings, and sessions), or at two different `claude`
installs, or at the same one with `--model opus`.

Profiles are generic: any adapter + any command + any args + any env map. All of
it applies only to that agent's process at spawn time; your shell, git, and ssh
config are untouched (profiles set `CLAUDE_CONFIG_DIR`, not `HOME`).

## Defining profiles

In the app: open **Settings › Launch profiles** — the gear in the header (or
`⌃,`), the gear beside the **Agent** dropdown, `manage profiles` in the New
initiative overlay, or `Launch profiles` in the command palette (⌃P). **New profile** asks for a
name, a base adapter, the command, the arguments, and the environment variables
to set; the suggested variable follows the adapter you pick
(`CLAUDE_CONFIG_DIR` for claude, `CODEX_HOME` for codex). Editing writes
straight to `~/.codrift/settings.json`, so the file and the view are always the
same thing.

By hand, it is a `"profiles"` object in `~/.codrift/settings.json`, keyed by
name:

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

- `adapter` — the base tool the profile launches (`claude`, `codex`, …). It
  decides the arguments, session handling, and status parsing. A profile can't
  be *named* after a base adapter: the Agent dropdown lists both and resolves by
  name, so `claude` as a profile name would shadow the real one.
- `command` — optional. The executable to run instead of the adapter's own. A
  bare name is looked up in `PATH` (a wrapper script called `claude-work` works
  exactly as it does in a shell); anything containing a `/` or starting with `~`
  is treated as a path. Omit it to run the adapter's default. The command is
  resolved when you save, so a typo is rejected in the form rather than showing
  up later as a terminal that dies on open.
- `args` — optional. Arguments appended to the ones the adapter already passes
  (`--resume`, `--add-dir`, …). One entry per argument, never a command line to
  be split: `["--model", "opus"]` is two entries, and `"be terse"` is one entry
  that needs no quoting. The app edits these as numbered rows for the same
  reason.
- `env` — environment variables merged into the agent's process. Values
  starting with `~` are expanded to absolute paths. These override the adapter's
  own defaults for the same key.

First-time setup for a Claude profile: create the config dir and log in under it,
e.g. `CLAUDE_CONFIG_DIR=~/.claude-work claude` and complete the login once. From
then on that folder holds that account's credentials and sessions.

## Choosing which agent runs

Each initiative has one agent, and it is asked for up front:

- **At creation.** The New initiative overlay (`n`) carries an **Agent** picker
  next to the name. Whatever you choose is stored on the initiative *and*
  becomes `default_agent` in `~/.codrift/settings.json`, so the next initiative
  starts from the same answer.
- **Afterwards.** `p` on the selected initiative opens a filterable list of every
  adapter and profile — `↑↓` to move, `Enter` to apply, `⇥` to aim the same list
  at `default_agent` instead. The **Agent** dropdown in the Context view does the
  same thing with the mouse. Both persist immediately.
- **Falling back.** An initiative with no agent of its own uses `default_agent`;
  with neither set, plain `claude`.

Starting an agent (`s`, or the per-directory **start** button) uses that choice —
no adapter is passed, so the initiative's answer is what runs. Running agents
show their profile as a badge in the sidebar.

**From an agent / MCP:** `start_agent` still accepts explicit `adapter` and
`profile` arguments, which win over the initiative's choice; omit both and the
initiative's agent runs. `list_agent_profiles` returns the available profiles.

## How it works

`get_agent_profiles`, `save_agent_profile` and `delete_agent_profile` are the
operations behind the view (`Codrift.Core`); they read and write the `profiles`
key through `Codrift.Config.Settings`. They are UI operations, not MCP tools —
`list_agent_profiles` (name + adapter only) is what agents see, so profile env
never lands in an agent's context by default. `get_default_agent`,
`set_default_agent` and `set_initiative_agent` back the pickers above.

At spawn, Codrift resolves the profile's base adapter, resolves its command to
an absolute path, appends its args to the adapter's own, expands its env, and
injects all of it into the agent's process (`process.ex`, merged so profile env
wins). For Claude, the profile's
`CLAUDE_CONFIG_DIR` is also threaded into session-file detection so `--resume`
vs `--session-id` resolves under the right config dir.
