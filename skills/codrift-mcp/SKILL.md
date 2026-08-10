---
name: codrift-mcp
description: Use when connecting an AI CLI to Codrift's MCP server, debugging a connection that isn't working, or wiring up a client Codrift doesn't auto-register. Triggers on "codrift mcp install", "connect Codrift to Claude Code", "MCP server", "SSE endpoint", "X-Codrift-Token", "auth-token", "the codrift tools aren't showing up", "port 43117", or registering Codrift with Codex, Gemini, Copilot or Opencode.
---

# Codrift MCP server

While the Codrift app is running it serves an MCP endpoint over SSE. Connecting
a CLI to it is what gives that CLI the initiative, memory, agent and integration
tools the other `codrift-*` skills describe.

## Register everything in one shot

```bash
codrift mcp install
```

It detects Claude Code, Gemini, Opencode, Codex and Copilot in `PATH` and
registers each one it finds, embedding the local auth token. Re-running it is
safe — it removes and re-adds rather than failing on an existing entry.

This needs the `codrift` CLI on `PATH`. Homebrew installs it alongside the app
(the cask depends on the `codrift-cli` formula); the curl installer puts it in
`~/.local/bin`.

## The endpoint, by hand

For any client `codrift mcp install` doesn't cover:

| | |
|---|---|
| URL | `http://localhost:43117/mcp/sse` |
| Transport | SSE |
| Auth header | `X-Codrift-Token: <token>` |
| Token file | `~/.codrift/auth-token` |

Claude Code, manually:

```bash
claude mcp add codrift --scope user --transport sse \
  http://localhost:43117/mcp/sse \
  --header "X-Codrift-Token: $(cat ~/.codrift/auth-token)"
```

Use `--scope user`, not the default `local` — `local` binds the server to
whatever directory you happened to run the command in, so the tools vanish the
moment you work somewhere else.

`codrift mcp install --port=<port>` if you have moved the server.

## When the tools don't show up

Work down this list:

1. **Is the app running?** The MCP server lives inside Codrift. No app, no
   endpoint. `codrift start` launches it.
2. **Right port?** 43117 is fixed, not negotiated — OAuth redirect URIs are
   registered against it ahead of time. If something else holds the port,
   Codrift will not silently move.
3. **Registered at user scope?** A `local`-scoped registration only works in one
   directory. Re-run `codrift mcp install`.
4. **Token present?** Read-only calls pass, state-changing ones are rejected by
   `Codrift.Plugs.LocalGuard` without a valid `X-Codrift-Token`. If listing works
   but creating fails, the header is missing or stale — re-run the installer,
   which re-reads `~/.codrift/auth-token`.
5. **Restarted the client?** Most CLIs read their MCP config at startup.

The guard also rejects cross-origin and DNS-rebinding requests, so the endpoint
is not reachable from a browser page — that is deliberate, not a bug to route
around.

## What you get once connected

| Category | Tools | Skill |
|---|---|---|
| Initiatives | `list_initiatives`, `create_initiative`, `add_dir`, `set_initiative_status`, `get_diff` | `codrift-initiatives` |
| Memory | `memory_search`, `memory_add`, `memory_delete`, `memory_recent`, `memory_list` | `codrift-memory` |
| Agents | `start_agent`, `send_to_agent`, `get_agent_output`, `broadcast_to_initiative` | `codrift-orchestration` |
| Conductor | `start_conductor`, `start_orchestration`, `get_conductor_status`, `stop_orchestration` | `codrift-orchestration` |
| Integrations | `start_oauth_flow`, `list_assigned_items`, `import_from_integration` | `codrift-integrations` |
| Profiles | `list_agent_profiles` | `codrift-profiles` |

## Sessions

Agent sessions persist across restarts, so a Claude agent resumes where it left
off rather than starting cold. Housekeeping:

```bash
codrift session list
codrift session prune
```
