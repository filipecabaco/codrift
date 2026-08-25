defmodule Codrift.MCP.Handler do
  @moduledoc """
  MCP (Model Context Protocol) JSON-RPC 2.0 handler.

  Receives decoded request maps from `POST /mcp`, dispatches to the appropriate
  tool, and returns a JSON-encoded response string.

  ## Supported methods

    - `initialize` — returns server capabilities
    - `tools/list` — returns the list of available tools
    - `tools/call` — invokes a named tool with arguments

  ## Tools

    - `list_initiatives` — list all initiatives
    - `get_diff` — git diff for an initiative
    - `list_agents` — running agents
    - `get_initiative_agents` — running agents filtered by initiative, with status
    - `start_agent` — spawn an agent in a directory
    - `open_terminal` — put a shell in front of the user for a step only they can do
    - `send_to_agent` — send input to a running agent
    - `get_agent_output` — fetch recent output from an agent
    - `broadcast_to_initiative` — send the same prompt to all agents in an initiative
    - `create_initiative` — create a new initiative
    - `add_dir` — add a directory to an initiative
    - `delete_initiative` — delete an initiative
    - `set_initiative_status` — set initiative lifecycle status
    - `list_worktrees` — Codrift-managed git worktrees and what still claims them
    - `set_dir_worktree` — turn a worktree on or off for one directory
    - `prune_worktrees` — remove worktrees nothing claims (dry run unless forced)
    - `memory_search` — FTS5 full-text search over an initiative's memory store
    - `memory_add` — store a new memory entry (decision/summary/snippet/file_context/note)
    - `memory_delete` — delete a memory entry by id
    - `memory_recent` — return the most recent memory entries
    - `memory_list` — return all entries of a specific type
    - `start_oauth_flow` — start OAuth2 browser-based authorization for a service
    - `get_oauth_status` — which services have active OAuth2 tokens
    - `list_integration_items` — list issues/tasks from a connected external service
    - `list_assigned_items` — list work assigned to the user across all connected services
    - `import_from_integration` — create an initiative from an external item
    - `sync_initiative_context` — re-fetch and overwrite the integration context file
    - `start_conductor` — start fan-out mode: one agent per directory
    - `start_orchestration` — start orchestration mode: one orchestrator agent plans and directs sub-agents
    - `get_conductor_status` — get the status of all agents under a conductor
    - `get_conductor_results` — get aggregated output from all conductor agents
    - `read_orchestration_md` — read the orchestration.md intent file for an initiative
    - `update_orchestration_md` — overwrite the orchestration.md intent file for an initiative
  """

  alias Codrift.OAuth.Config, as: OAuthConfig

  @server_info %{
    "protocolVersion" => "2024-11-05",
    "capabilities" => %{"tools" => %{}},
    "serverInfo" => %{"name" => "codrift", "version" => "0.1.0"}
  }

  @doc "Returns the raw server-info map (used for the MCP SSE endpoint event)."
  def server_info, do: @server_info

  @doc """
  Dispatches an already-decoded MCP JSON-RPC request map.

  Returns a JSON-encoded response string ready to send as the HTTP body.
  """

  def dispatch(%{"method" => "initialize", "id" => id}) do
    encode_ok(id, @server_info)
  end

  def dispatch(%{"method" => "tools/list", "id" => id}) do
    encode_ok(id, %{"tools" => tool_definitions()})
  end

  def dispatch(%{"method" => "tools/call", "params" => params, "id" => id}) do
    name = params["name"]
    args = params["arguments"] || %{}

    case Codrift.Core.call(name, args) do
      {:ok, result} ->
        encode_ok(id, %{"content" => [%{"type" => "text", "text" => JSON.encode!(result)}]})

      {:error, msg} ->
        encode_error(id, -32_603, msg)
    end
  rescue
    e -> encode_error(id, -32_603, Exception.message(e))
  end

  def dispatch(%{"id" => id}) do
    encode_error(id, -32_601, "Method not found")
  end

  def dispatch(_) do
    encode_error(nil, -32_600, "Invalid request")
  end

  @doc """
  True when `request` is a JSON-RPC *notification* — a call carrying a `method`
  but no `id`, such as the `notifications/initialized` every MCP client sends
  right after `initialize`.

  JSON-RPC 2.0 forbids answering one. Without this check a notification falls
  through to the catch-all `dispatch/1` clause and comes back as
  `-32600 Invalid request` with a null id, which is a response to a message
  that must not be responded to at all.
  """
  @spec notification?(term()) :: boolean()
  def notification?(%{"method" => _} = request), do: not Map.has_key?(request, "id")
  def notification?(_request), do: false

  defp encode_ok(id, result) do
    JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp encode_error(id, code, message) do
    JSON.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  @doc "Names of every tool this server advertises."
  @spec tool_names() :: [String.t()]
  def tool_names, do: Enum.map(tool_definitions(), & &1["name"])

  defp tool_definitions do
    [
      %{
        "name" => "list_initiatives",
        "description" => "List all initiatives",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name" => "create_initiative",
        "description" => "Create a new initiative with an optional list of directories",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string"},
            "dirs" => %{"type" => "array", "items" => %{"type" => "string"}}
          },
          "required" => ["name"]
        }
      },
      %{
        "name" => "add_dir",
        "description" => "Add a directory to an existing initiative (~ is expanded)",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{"type" => "string"},
            "dir" => %{"type" => "string"},
            "worktree" => %{
              "type" => "boolean",
              "description" =>
                "Work in an isolated git worktree on its own branch instead of the directory itself. Ignored when the directory is not a git repository."
            }
          },
          "required" => ["initiative_id", "dir"]
        }
      },
      %{
        "name" => "delete_initiative",
        "description" => "Delete an initiative by ID",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"initiative_id" => %{"type" => "string"}},
          "required" => ["initiative_id"]
        }
      },
      %{
        "name" => "set_initiative_status",
        "description" =>
          "Set the lifecycle status of an initiative (planning, ongoing, done, archived)",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{"type" => "string"},
            "status" => %{
              "type" => "string",
              "enum" => ["planning", "ongoing", "done", "archived"]
            }
          },
          "required" => ["initiative_id", "status"]
        }
      },
      %{
        "name" => "get_diff",
        "description" => "Get current git diff for all directories in an initiative",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"initiative_id" => %{"type" => "string"}},
          "required" => ["initiative_id"]
        }
      },
      %{
        "name" => "list_agents",
        "description" => "List all running AI coding agents",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name" => "get_initiative_agents",
        "description" =>
          "List all running agents for a specific initiative with their status and directory. " <>
            "Use this to check which agents are still working and which are idle or stopped.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"initiative_id" => %{"type" => "string"}},
          "required" => ["initiative_id"]
        }
      },
      %{
        "name" => "broadcast_to_initiative",
        "description" =>
          "Send the same prompt to every running agent in an initiative at once. " <>
            "Useful when all agents need the same instruction (e.g. 'run tests and report results').",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{"type" => "string"},
            "input" => %{"type" => "string", "description" => "Prompt to send to all agents"}
          },
          "required" => ["initiative_id", "input"]
        }
      },
      %{
        "name" => "start_agent",
        "description" =>
          "Start an AI coding agent in a directory. Omit `dir` for a folderless " <>
            "initiative — the agent runs in the initiative's own context " <>
            "folder. For a shell the *user* is meant to drive, use `open_terminal` " <>
            "instead — it opens a pane and moves their keyboard into it.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{"type" => "string"},
            "dir" => %{
              "type" => "string",
              "description" =>
                "Working directory. Optional — defaults to the initiative's context folder."
            },
            "adapter" => %{
              "type" => "string",
              "enum" => ["claude", "codex", "opencode", "gemini", "copilot", "cursor"]
            },
            "profile" => %{
              "type" => "string",
              "description" =>
                "Optional launch profile name (from settings.json) — runs the " <>
                  "adapter under that profile's config folder/account, e.g. " <>
                  "\"claude-work\". See list_agent_profiles."
            }
          },
          "required" => ["initiative_id", "adapter"]
        }
      },
      %{
        "name" => "open_terminal",
        "description" =>
          "Open an interactive shell in front of the user, in a Codrift pane that " <>
            "takes the keyboard. Use this when a step needs a human — anything you " <>
            "are not permitted to run yourself (`git commit`, `git push`, a deploy), " <>
            "a credential prompt, or a choice only they can make. Pass `command` to " <>
            "draft the command line for them: it is TYPED AT THE PROMPT BUT NOT RUN, " <>
            "so they read it and press Return themselves. State `reason` — it is " <>
            "shown to them as the terminal opens, and it is the only explanation " <>
            "they get for why their keyboard just moved. Poll `get_agent_output` to " <>
            "see what happened, and do not assume the command ran.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{"type" => "string"},
            "dir" => %{
              "type" => "string",
              "description" =>
                "Working directory for the shell. Optional — defaults to the " <>
                  "initiative's context folder."
            },
            "command" => %{
              "type" => "string",
              "description" =>
                "Single-line command to type at the prompt without running it. " <>
                  "Newlines are flattened to spaces so nothing can submit itself; " <>
                  "use repeated flags (e.g. two `-m`) rather than embedded newlines."
            },
            "reason" => %{
              "type" => "string",
              "description" =>
                "One line telling the user what you need from them, e.g. " <>
                  "\"review and commit the staged auth changes\"."
            }
          },
          "required" => ["initiative_id"]
        }
      },
      %{
        "name" => "focus_agent",
        "description" =>
          "Bring an already-running agent or terminal into a pane and give it the " <>
            "user's keyboard. Use it to hand back to a session you opened earlier " <>
            "instead of opening a second one, or to point the user at an agent that " <>
            "is blocked waiting on them.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "agent_id" => %{"type" => "string"},
            "reason" => %{
              "type" => "string",
              "description" => "One line telling the user why they are being sent here."
            }
          },
          "required" => ["agent_id"]
        }
      },
      %{
        "name" => "list_agent_profiles",
        "description" =>
          "List configured launch profiles (name + base adapter). Pass a name as " <>
            "`profile` to start_agent to run under that profile's config folder/account.",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name" => "send_to_agent",
        "description" => "Send a prompt or input to a running agent",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "agent_id" => %{"type" => "string"},
            "input" => %{"type" => "string"}
          },
          "required" => ["agent_id", "input"]
        }
      },
      %{
        "name" => "get_agent_output",
        "description" => "Get recent output from a running agent",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "agent_id" => %{"type" => "string"},
            "n" => %{"type" => "integer", "description" => "Number of lines (default 50)"}
          },
          "required" => ["agent_id"]
        }
      },
      %{
        "name" => "list_worktrees",
        "description" =>
          "List Codrift-managed git worktrees. Each lives at " <>
            "~/.codrift/initiatives/<id>/worktrees/<slug>. `state` is \"linked\" when an " <>
            "initiative still claims it, or \"orphan\" when nothing does — `reason` says " <>
            "whether the initiative was deleted or the directory was removed from it. " <>
            "`dirty` means the worktree has uncommitted changes.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{
              "type" => "string",
              "description" => "Optional — restrict the listing to one initiative"
            }
          },
          "required" => []
        }
      },
      %{
        "name" => "prune_worktrees",
        "description" =>
          "Remove worktrees no initiative claims, and clear stale git registrations " <>
            "(worktrees a repository still lists after the folder is gone). " <>
            "DRY RUN BY DEFAULT: without force=true nothing is deleted and the result " <>
            "only reports what would be. Check `dirty` on each orphan before forcing — " <>
            "a dirty worktree holds uncommitted work that removal destroys. Committed " <>
            "work is never lost: removing a worktree leaves its branch in place.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "force" => %{
              "type" => "boolean",
              "description" => "Actually remove. Defaults to false — report only."
            }
          },
          "required" => []
        }
      },
      %{
        "name" => "set_dir_worktree",
        "description" =>
          "Turn a git worktree on or off for one directory of an initiative. Enabling " <>
            "checks the directory out into ~/.codrift/initiatives/<id>/worktrees/<slug> on " <>
            "its own codrift/<id>/<slug> branch, so agents work there instead of the " <>
            "source checkout. Idempotent, and disabling keeps the branch.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{"type" => "string"},
            "dir" => %{
              "type" => "string",
              "description" => "A directory already on the initiative"
            },
            "enabled" => %{
              "type" => "boolean",
              "description" => "true to create the worktree, false to remove it. Default true."
            }
          },
          "required" => ["initiative_id", "dir"]
        }
      },
      %{
        "name" => "memory_search",
        "description" =>
          "Search an initiative's memory store. Ask a whole question in plain language — " <>
            "terms are OR-joined and ranked by relevance, so you do not need to guess keywords. " <>
            "Returns up to 20 entries, best match first.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{"type" => "string"},
            "query" => %{
              "type" => "string",
              "description" =>
                "A question or a few words. Terms are OR-joined and stopwords dropped, " <>
                  "so \"does a sprite sleep while an agent is working\" works as written. " <>
                  "Quote a phrase to require it verbatim, use AND/OR/NOT to be explicit, " <>
                  "and end a term with * for a prefix match."
            }
          },
          "required" => ["initiative_id", "query"]
        }
      },
      %{
        "name" => "memory_add",
        "description" =>
          "Add a memory entry. Use after completing a task, making a decision, or finding a reusable pattern.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{"type" => "string"},
            "chunk_type" => %{
              "type" => "string",
              "enum" => Codrift.Memory.valid_types(),
              "description" => "decision | summary | snippet | file_context | note"
            },
            "content" => %{"type" => "string"},
            "source" => %{
              "type" => "string",
              "description" => "Who wrote this (agent ID, file path, etc). Defaults to 'mcp'."
            }
          },
          "required" => ["initiative_id", "chunk_type", "content"]
        }
      },
      %{
        "name" => "memory_delete",
        "description" =>
          "Delete a memory entry by id (from memory_search or memory_add). Removes outdated entries.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{"type" => "string"},
            "id" => %{"type" => "integer"}
          },
          "required" => ["initiative_id", "id"]
        }
      },
      %{
        "name" => "memory_recent",
        "description" => "Return the most recent memory entries across all types, newest first.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{"type" => "string"},
            "limit" => %{
              "type" => "integer",
              "description" => "Max entries to return (default 20)"
            }
          },
          "required" => ["initiative_id"]
        }
      },
      %{
        "name" => "memory_list",
        "description" => "Return all memory entries of a specific type, newest first.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{"type" => "string"},
            "chunk_type" => %{
              "type" => "string",
              "enum" => Codrift.Memory.valid_types()
            }
          },
          "required" => ["initiative_id", "chunk_type"]
        }
      },
      %{
        "name" => "start_oauth_flow",
        "description" =>
          "Start an OAuth2 authorization flow for a service. Returns a URL for the user " <>
            "to open in their browser. The Codrift server handles the callback and stores " <>
            "the token automatically. Preferred over API key env vars.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "service" => %{
              "type" => "string",
              "enum" => OAuthConfig.supported_services(),
              "description" => "Service to authorize"
            }
          },
          "required" => ["service"]
        }
      },
      %{
        "name" => "get_oauth_status",
        "description" => "Returns which external services have active OAuth2 tokens stored.",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name" => "list_integration_items",
        "description" =>
          "List open issues or tasks from a connected external service. " <>
            "Returns id, title, url, status, assignee, and labels for each item. " <>
            "Use import_from_integration to turn one into an initiative.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "service" => %{
              "type" => "string",
              "enum" => Codrift.Integration.valid_services(),
              "description" => "Integration service name"
            },
            "filter" => %{
              "type" => "string",
              "description" =>
                "Service-specific filter: GitHub/GitLab state (open/closed/all), " <>
                  "Linear team key, GitHub Projects owner/number (e.g. acme/5)"
            }
          },
          "required" => ["service"]
        }
      },
      %{
        "name" => "list_assigned_items",
        "description" =>
          "List everything assigned to the authenticated user across every connected " <>
            "service. Each item includes its service and, when it was already imported, " <>
            "the initiative_id it belongs to — import only items where imported is false.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "filter" => %{
              "type" => "string",
              "description" => "Optional service-specific state filter (e.g. open, opened)"
            }
          }
        }
      },
      %{
        "name" => "import_from_integration",
        "description" =>
          "Create a Codrift initiative from a single item in an external service. " <>
            "Fetches the item, creates an initiative named after it, and writes " <>
            "the item's full context into the initiative.md source block.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "service" => %{
              "type" => "string",
              "enum" => Codrift.Integration.valid_services()
            },
            "item_id" => %{
              "type" => "string",
              "description" =>
                "Service-specific item identifier: " <>
                  "GitHub owner/repo#number, Linear ENG-123 or UUID, " <>
                  "GitLab project#iid"
            },
            "dir" => %{
              "type" => "string",
              "description" => "Optional working directory path to add to the initiative"
            }
          },
          "required" => ["service", "item_id"]
        }
      },
      %{
        "name" => "sync_initiative_context",
        "description" =>
          "Re-fetch the external item and refresh the source block of initiative.md " <>
            "that was previously created via import_from_integration.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{"type" => "string"}
          },
          "required" => ["initiative_id"]
        }
      },
      %{
        "name" => "start_conductor",
        "description" =>
          "Start fan-out mode for an initiative: automatically spawns one agent per working directory. " <>
            "All agents start immediately without a planning step.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{"type" => "string"},
            "adapter" => %{
              "type" => "string",
              "enum" => ["claude", "codex", "opencode", "gemini", "copilot", "cursor"],
              "description" => "AI agent adapter to use (default: claude)"
            }
          },
          "required" => ["initiative_id"]
        }
      },
      %{
        "name" => "start_orchestration",
        "description" =>
          "Start orchestration mode for an initiative: one orchestrator agent reads orchestration.md " <>
            "and uses Codrift MCP tools to plan, spawn, and coordinate sub-agents across directories.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{"type" => "string"},
            "task" => %{
              "type" => "string",
              "description" => "High-level task description passed to the orchestrator agent"
            },
            "adapter" => %{
              "type" => "string",
              "enum" => ["claude", "codex", "opencode", "gemini", "copilot", "cursor"],
              "description" => "AI agent adapter to use (default: claude)"
            },
            "context_dir" => %{
              "type" => "string",
              "description" =>
                "Override the context directory (default: ~/.codrift/initiatives/{id}/)"
            }
          },
          "required" => ["initiative_id", "task"]
        }
      },
      %{
        "name" => "stop_orchestration",
        "description" =>
          "Stop the conductor running for an initiative, terminating the orchestrator and every " <>
            "sub-agent it spawned. Returns `stopped: false` when nothing was running.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"initiative_id" => %{"type" => "string"}},
          "required" => ["initiative_id"]
        }
      },
      %{
        "name" => "get_conductor_status",
        "description" =>
          "Get the status of all agents managed by a conductor for an initiative. " <>
            "Returns agent IDs, their working directories, current status, and role (orchestrator/worker).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"initiative_id" => %{"type" => "string"}},
          "required" => ["initiative_id"]
        }
      },
      %{
        "name" => "get_conductor_results",
        "description" =>
          "Get aggregated output from all agents managed by a conductor, keyed by agent ID.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"initiative_id" => %{"type" => "string"}},
          "required" => ["initiative_id"]
        }
      },
      %{
        "name" => "read_orchestration_md",
        "description" =>
          "Read the orchestration.md intent file for an initiative. " <>
            "This file defines the orchestrator's goal, strategy, and success criteria.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"initiative_id" => %{"type" => "string"}},
          "required" => ["initiative_id"]
        }
      },
      %{
        "name" => "update_orchestration_md",
        "description" =>
          "Overwrite the orchestration.md intent file for an initiative. " <>
            "Use this to set the goal, strategy, and instructions before starting orchestration.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{"type" => "string"},
            "content" => %{
              "type" => "string",
              "description" => "New Markdown content for orchestration.md"
            }
          },
          "required" => ["initiative_id", "content"]
        }
      }
    ]
  end
end
