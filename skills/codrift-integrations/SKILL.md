---
name: codrift-integrations
description: Use when pulling work into Codrift from GitHub, Linear, or GitLab — listing assigned issues, importing one into an initiative, refreshing imported context, or connecting a service via OAuth. Triggers on "import this issue", "what's assigned to me", "Linear ticket", "GitHub issue", "GitLab", "connect my tracker", "OAuth", "sync the initiative context", or turning a ticket into work.
---

# Codrift integrations

Codrift imports issues and tasks from **GitHub** (Issues & Projects), **Linear**
(Issues & Projects) and **GitLab** into initiatives, carrying the item's full
context with it.

## Check the connection first

```
get_oauth_status {}      # which services have live tokens
```

If the service you need is missing, start the flow and hand the URL to the user
— you cannot complete it yourself, it needs a browser:

```
start_oauth_flow { service: "github" }   # returns a URL for the user to open
```

The Codrift server handles the callback and stores the token at
`~/.codrift/oauth_tokens.json` (mode 0600). Released builds ship working client
IDs, so there is nothing for the user to register. Env vars are a fallback for
CI and headless use.

Report the URL and stop. Do not poll for completion in a tight loop.

## Find the work

```
list_assigned_items {}                          # across every connected service
list_assigned_items { filter: "open" }
list_integration_items { service: "github", filter: "open" }
```

`list_assigned_items` is the one to reach for when the user says "what am I
supposed to be working on" — it spans all services, and each item carries:

- `service` — where it came from
- `imported` — **check this.** When `true`, the item already has an initiative.
- `initiative_id` — that initiative, when it exists

**Import only items where `imported` is false.** Re-importing creates a second
initiative for the same ticket and splits the work in two.

`filter` on `list_integration_items` is service-specific:

| Service | `filter` means |
|---|---|
| GitHub / GitLab | state — `open`, `closed`, `all` |
| Linear | a team key |
| GitHub Projects | `owner/number`, e.g. `acme/5` |

## Import one item

```
import_from_integration {
  service: "linear",
  item_id: "ENG-123",
  dir: "~/projects/api"        # optional
}
```

This creates an initiative named after the item and writes the item's full
context into the source block of `initiative.md`.

Item id formats:

| Service | `item_id` |
|---|---|
| GitHub | `owner/repo#number` |
| Linear | `ENG-123` or the UUID |
| GitLab | `project#iid` |

## Keep imported context fresh

```
sync_initiative_context { initiative_id }
```

Re-fetches the external item and refreshes **only** the source block that
`import_from_integration` created. Anything you or the user wrote elsewhere in
`initiative.md` is preserved — so append your own notes outside that block and
they will survive a sync.

Sync when the ticket has likely moved since import: a long-running initiative,
or a user who says the requirements changed.

## CLI

```bash
codrift integration services
codrift integration auth   <service>
codrift integration list   <service>
codrift integration import <service> <item_id>
codrift integration revoke <service>
codrift integration tokens
```

## Notes

- Port **43117** is fixed — OAuth redirect URIs are registered ahead of time and
  cannot be renegotiated. If a redirect fails, that port is the thing to check.
- Tokens are the user's credentials. Never print them, and never copy
  `oauth_tokens.json` anywhere.

Full setup: [docs/integrations.md](https://github.com/filipecabaco/codrift/blob/main/docs/integrations.md)
