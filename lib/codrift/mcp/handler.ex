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
    - `send_to_agent` — send input to a running agent
    - `get_agent_output` — fetch recent output from an agent
    - `broadcast_to_initiative` — send the same prompt to all agents in an initiative
    - `create_initiative` — create a new initiative
    - `add_dir` — add a directory to an initiative
    - `delete_initiative` — delete an initiative
    - `set_initiative_status` — set initiative lifecycle status
    - `memory_search` — FTS5 full-text search over an initiative's memory store
    - `memory_add` — store a new memory entry (decision/summary/snippet/file_context/note)
    - `memory_delete` — delete a memory entry by id
    - `memory_recent` — return the most recent memory entries
    - `memory_list` — return all entries of a specific type
    - `start_oauth_flow` — start OAuth2 browser-based authorization for a service
    - `get_oauth_status` — which services have active OAuth2 tokens
    - `list_integration_items` — list issues/tasks from a connected external service
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

  @doc "Returns a JSON-encoded MCP parse-error response."
  def parse_error do
    encode_error(nil, -32_700, "Parse error")
  end

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
            "dir" => %{"type" => "string"}
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
            "initiative — the agent runs in the initiative's own scratchpad (context) folder.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{"type" => "string"},
            "dir" => %{
              "type" => "string",
              "description" =>
                "Working directory. Optional — defaults to the initiative's scratchpad folder."
            },
            "adapter" => %{
              "type" => "string",
              "enum" => ["claude", "codex", "opencode", "gemini", "copilot"]
            }
          },
          "required" => ["initiative_id", "adapter"]
        }
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
        "name" => "memory_search",
        "description" =>
          "Full-text search over an initiative's memory store. Returns up to 20 results ranked by relevance.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{"type" => "string"},
            "query" => %{
              "type" => "string",
              "description" =>
                "FTS5 query: plain words, quoted phrases, AND/OR/NOT operators supported"
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
        "name" => "save_guided_token",
        "description" =>
          "Saves a manually-obtained integration token for a service that uses guided " <>
            "token setup (e.g. Notion). Call this after showing the user the instructions " <>
            "from start_oauth_flow and receiving the token they pasted.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "service" => %{"type" => "string"},
            "token" => %{"type" => "string", "description" => "The integration token to save"}
          },
          "required" => ["service", "token"]
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
                  "Linear team key, Jira JQL query, Notion database ID, " <>
                  "GitHub Projects owner/number (e.g. acme/5), Asana project GID"
            }
          },
          "required" => ["service"]
        }
      },
      %{
        "name" => "import_from_integration",
        "description" =>
          "Create a Codrift initiative from a single item in an external service. " <>
            "Fetches the item, creates an initiative named after it, and writes " <>
            "integration.md with full context into the initiative folder.",
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
                  "GitLab project#iid, Jira ENG-42, Notion page ID, " <>
                  "Shortcut story ID, Asana task GID"
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
          "Re-fetch the external item and overwrite integration.md for an initiative " <>
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
              "enum" => ["claude", "codex", "opencode", "gemini", "copilot"],
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
              "enum" => ["claude", "codex", "opencode", "gemini", "copilot"],
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
