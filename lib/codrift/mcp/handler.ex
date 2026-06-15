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

  alias Codrift.Initiative.{DirEntry, Store}
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

    case call_tool(name, args) do
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

  defp call_tool("list_initiatives", _args) do
    {:ok, Enum.map(Store.list(), &Codrift.Initiative.to_map/1)}
  end

  defp call_tool("get_diff", %{"initiative_id" => initiative_id}) do
    case Store.get(initiative_id) do
      {:ok, initiative} ->
        {:ok,
         Enum.flat_map(initiative.dirs, fn entry -> dir_diffs(DirEntry.effective_path(entry)) end)}

      {:error, :not_found} ->
        {:error, "initiative not found: #{initiative_id}"}
    end
  end

  defp call_tool("list_agents", _args) do
    agents =
      Enum.map(Codrift.AgentSupervisor.list_agents(), fn pid ->
        pid
        |> Codrift.AgentProcess.status()
        |> Map.update!(:adapter, &Codrift.Agent.adapter_name/1)
        |> Map.update!(:status, &Atom.to_string/1)
      end)

    {:ok, agents}
  end

  defp call_tool("get_initiative_agents", %{"initiative_id" => initiative_id}) do
    agents =
      initiative_id
      |> Codrift.AgentSupervisor.list_agents_for_initiative()
      |> Enum.map(fn pid ->
        pid
        |> Codrift.AgentProcess.status()
        |> Map.update!(:adapter, &Codrift.Agent.adapter_name/1)
        |> Map.update!(:status, &Atom.to_string/1)
      end)

    {:ok, agents}
  end

  defp call_tool("broadcast_to_initiative", %{"initiative_id" => initiative_id, "input" => input}) do
    case Codrift.AgentSupervisor.list_agents_for_initiative(initiative_id) do
      [] ->
        {:error, "no running agents for initiative: #{initiative_id}"}

      pids ->
        Enum.each(pids, &Codrift.AgentProcess.send_input(&1, input))
        {:ok, %{"sent_to" => length(pids)}}
    end
  end

  defp call_tool(
         "start_agent",
         %{"initiative_id" => init_id, "dir" => dir, "adapter" => adapter}
       ) do
    module = adapter_module(adapter)
    expanded_dir = Path.expand(dir)

    case Codrift.AgentSupervisor.start_agent(init_id, expanded_dir, module) do
      {:ok, pid} ->
        status =
          pid
          |> Codrift.AgentProcess.status()
          |> Map.update!(:adapter, &Codrift.Agent.adapter_name/1)
          |> Map.update!(:status, &Atom.to_string/1)

        {:ok, status}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp call_tool("send_to_agent", %{"agent_id" => agent_id, "input" => input}) do
    case Codrift.AgentSupervisor.find_agent(agent_id) do
      {:ok, pid} ->
        Codrift.AgentProcess.send_input(pid, input)
        {:ok, %{"ok" => true}}

      {:error, :not_found} ->
        {:error, "agent not found: #{agent_id}"}
    end
  end

  defp call_tool("get_agent_output", %{"agent_id" => agent_id} = args) do
    n = args["n"] || 50

    case Codrift.AgentSupervisor.find_agent(agent_id) do
      {:ok, pid} -> {:ok, %{"output" => Codrift.AgentProcess.recent_output(pid, n)}}
      {:error, :not_found} -> {:error, "agent not found: #{agent_id}"}
    end
  end

  defp call_tool("create_initiative", %{"name" => name} = args) do
    dirs = Map.get(args, "dirs", [])

    case Store.create(name, dirs) do
      {:ok, initiative} -> {:ok, Codrift.Initiative.to_map(initiative)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp call_tool("add_dir", %{"initiative_id" => id, "dir" => dir}) do
    expanded = Path.expand(dir)

    case Store.add_dir(id, expanded) do
      {:ok, initiative} -> {:ok, Codrift.Initiative.to_map(initiative)}
      {:error, :not_found} -> {:error, "initiative not found: #{id}"}
    end
  end

  defp call_tool("delete_initiative", %{"initiative_id" => id}) do
    case Store.delete(id) do
      :ok -> {:ok, %{"deleted" => id}}
      {:error, :not_found} -> {:error, "initiative not found: #{id}"}
    end
  end

  defp call_tool("set_initiative_status", %{"initiative_id" => id, "status" => status_str}) do
    valid = ~w(planning ongoing done archived)

    if status_str in valid do
      status = String.to_existing_atom(status_str)

      case Store.set_status(id, status) do
        {:ok, initiative} -> {:ok, Codrift.Initiative.to_map(initiative)}
        {:error, :not_found} -> {:error, "initiative not found: #{id}"}
      end
    else
      {:error, "invalid status: #{status_str}. Must be one of: #{Enum.join(valid, ", ")}"}
    end
  end

  defp call_tool("memory_search", %{"initiative_id" => id, "query" => query}) do
    {:ok, Codrift.Memory.search(id, query)}
  end

  defp call_tool(
         "memory_add",
         %{"initiative_id" => id, "chunk_type" => type, "content" => content} = args
       ) do
    source = Map.get(args, "source", "mcp")
    valid = Codrift.Memory.valid_types()

    if type in valid do
      case Codrift.Memory.add(id, type, content, source) do
        {:ok, rowid} -> {:ok, %{"id" => rowid}}
      end
    else
      {:error, "invalid chunk_type '#{type}'. Must be one of: #{Enum.join(valid, ", ")}"}
    end
  end

  defp call_tool("memory_delete", %{"initiative_id" => id, "id" => rowid})
       when is_integer(rowid) do
    case Codrift.Memory.delete(id, rowid) do
      :ok -> {:ok, %{"deleted" => rowid}}
      {:error, :not_found} -> {:error, "memory entry not found: #{rowid}"}
    end
  end

  defp call_tool("memory_delete", %{"initiative_id" => _id, "id" => rowid}) do
    {:error, "id must be an integer, got: #{inspect(rowid)}"}
  end

  defp call_tool("memory_recent", %{"initiative_id" => id} = args) do
    limit = args |> Map.get("limit", 20) |> clamp_limit()
    {:ok, Codrift.Memory.recent(id, limit)}
  end

  defp call_tool("memory_list", %{"initiative_id" => id, "chunk_type" => type}) do
    valid = Codrift.Memory.valid_types()

    if type in valid do
      {:ok, Codrift.Memory.list(id, type)}
    else
      {:error, "invalid chunk_type '#{type}'. Must be one of: #{Enum.join(valid, ", ")}"}
    end
  end

  defp call_tool("start_oauth_flow", %{"service" => service}) do
    case Codrift.OAuth.start_flow(service) do
      {:ok, %{flow: :pkce_browser, auth_url: url}} ->
        {:ok,
         %{
           flow: "pkce_browser",
           service: service,
           auth_url: url,
           message:
             "Open this URL in a browser to authorize #{service}. " <>
               "The Codrift server will save the token automatically."
         }}

      {:ok, %{flow: :guided_token, instructions: instructions}} ->
        {:ok,
         %{
           flow: "guided_token",
           service: service,
           instructions: instructions,
           message:
             "Show these instructions to the user, ask them to paste the token, " <>
               "then call save_guided_token once you have it."
         }}

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  defp call_tool("save_guided_token", %{"service" => service, "token" => token}) do
    case Codrift.OAuth.save_guided_token(service, token) do
      :ok -> {:ok, %{connected: true, service: service}}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  defp call_tool("get_oauth_status", _args) do
    all = OAuthConfig.supported_services()

    status =
      Map.new(all, fn service ->
        {service,
         %{
           connected: Codrift.OAuth.connected?(service),
           oauth_supported: true
         }}
      end)

    {:ok, %{services: status}}
  end

  defp call_tool("list_integration_items", %{"service" => service} = args) do
    opts = if filter = args["filter"], do: [filter: filter], else: []

    with {:ok, adapter} <- Codrift.Integration.adapter_for(service),
         {:ok, items} <- adapter.list_items(opts) do
      {:ok, Enum.map(items, &integration_item_to_map/1)}
    end
  end

  defp call_tool(
         "import_from_integration",
         %{"service" => service, "item_id" => item_id} = args
       ) do
    opts = if dir = args["dir"], do: [dir: dir], else: []

    case Codrift.Integration.import_item(service, item_id, opts) do
      {:ok, initiative} -> {:ok, Codrift.Initiative.to_map(initiative)}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  defp call_tool("sync_initiative_context", %{"initiative_id" => id}) do
    case Codrift.Integration.sync_initiative(id) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  defp call_tool("start_conductor", %{"initiative_id" => id} = args) do
    case Store.get(id) do
      {:ok, initiative} ->
        adapter = args |> Map.get("adapter", "claude") |> adapter_module()

        case Codrift.ConductorSupervisor.start_conductor(initiative, adapter) do
          {:ok, pid} ->
            {:ok, %{"started" => true, "initiative_id" => id, "pid" => inspect(pid)}}

          {:error, {:already_started, _}} ->
            {:ok, %{"started" => false, "reason" => "already running"}}

          {:error, reason} ->
            {:error, inspect(reason)}
        end

      {:error, :not_found} ->
        {:error, "initiative not found: #{id}"}
    end
  end

  defp call_tool("start_orchestration", %{"initiative_id" => id, "task" => task} = args) do
    case Store.get(id) do
      {:ok, initiative} ->
        adapter = args |> Map.get("adapter", "claude") |> adapter_module()
        extra = if dir = args["context_dir"], do: [context_dir: dir], else: []

        case Codrift.ConductorSupervisor.start_orchestration(initiative, adapter, task, extra) do
          {:ok, pid} ->
            {:ok, %{"started" => true, "initiative_id" => id, "pid" => inspect(pid)}}

          {:error, {:already_started, _}} ->
            {:ok, %{"started" => false, "reason" => "already running"}}

          {:error, reason} ->
            {:error, inspect(reason)}
        end

      {:error, :not_found} ->
        {:error, "initiative not found: #{id}"}
    end
  end

  defp call_tool("get_conductor_status", %{"initiative_id" => id}) do
    case Codrift.ConductorSupervisor.find_conductor(id) do
      {:ok, pid} ->
        statuses =
          pid
          |> Codrift.Conductor.agent_status()
          |> Map.new(fn {agent_id, info} ->
            {agent_id,
             %{
               dir: info.dir,
               status: Atom.to_string(info.status),
               role: Atom.to_string(info.role)
             }}
          end)

        {:ok, %{"initiative_id" => id, "agents" => statuses}}

      {:error, :not_found} ->
        {:error, "no conductor running for initiative: #{id}"}
    end
  end

  defp call_tool("get_conductor_results", %{"initiative_id" => id}) do
    case Codrift.ConductorSupervisor.find_conductor(id) do
      {:ok, pid} ->
        results =
          pid
          |> Codrift.Conductor.results()
          |> Map.new(fn {agent_id, chunks} -> {agent_id, Enum.join(chunks)} end)

        {:ok, %{"initiative_id" => id, "results" => results}}

      {:error, :not_found} ->
        {:error, "no conductor running for initiative: #{id}"}
    end
  end

  defp call_tool("read_orchestration_md", %{"initiative_id" => id}) do
    case Store.read_orchestration_md(id) do
      {:ok, content} -> {:ok, %{"initiative_id" => id, "content" => content}}
      {:error, reason} -> {:error, "could not read orchestration.md: #{inspect(reason)}"}
    end
  end

  defp call_tool("update_orchestration_md", %{"initiative_id" => id, "content" => content}) do
    case Store.update_orchestration_md(id, content) do
      :ok -> {:ok, %{"updated" => true, "initiative_id" => id}}
      {:error, reason} -> {:error, "could not write orchestration.md: #{inspect(reason)}"}
    end
  end

  defp call_tool(name, _args), do: {:error, "unknown tool: #{name}"}

  defp integration_item_to_map(%Codrift.Integration.Item{} = item) do
    %{
      id: item.id,
      title: item.title,
      url: item.url,
      status: item.status,
      assignee: item.assignee,
      labels: item.labels || []
    }
  end

  defp dir_diffs(dir) do
    case Codrift.Diff.generate(dir) do
      {:ok, files} -> Enum.map(files, &Codrift.Diff.to_map/1)
      {:error, _} -> []
    end
  end

  defp adapter_module(name) do
    Codrift.Agent.module_from_name(name) || raise("unknown adapter: #{name}")
  end

  # Clamps memory_recent limit to 1..100.  Accepts integers only; any other
  # type (float, nil) falls back to the default of 20.
  defp clamp_limit(n) when is_integer(n) and n > 0, do: min(n, 100)
  defp clamp_limit(_), do: 20

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
        "description" => "Start an AI coding agent in a directory",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{"type" => "string"},
            "dir" => %{"type" => "string"},
            "adapter" => %{
              "type" => "string",
              "enum" => ["claude", "codex", "opencode", "gemini", "copilot"]
            }
          },
          "required" => ["initiative_id", "dir", "adapter"]
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
