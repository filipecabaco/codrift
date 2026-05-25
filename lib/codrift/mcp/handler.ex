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
    - `start_agent` — spawn an agent in a directory
    - `send_to_agent` — send input to a running agent
    - `get_agent_output` — fetch recent output from an agent
  """

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
    {:ok, Enum.map(Codrift.Initiative.Store.list(), &Codrift.Initiative.to_map/1)}
  end

  defp call_tool("get_diff", %{"initiative_id" => initiative_id}) do
    case Codrift.Initiative.Store.get(initiative_id) do
      {:ok, initiative} -> {:ok, Enum.flat_map(initiative.dirs, &dir_diffs/1)}
      {:error, :not_found} -> {:error, "initiative not found: #{initiative_id}"}
    end
  end

  defp call_tool("list_agents", _args) do
    agents =
      Enum.map(Codrift.AgentSupervisor.list_agents(), fn pid ->
        pid
        |> Codrift.AgentProcess.status()
        |> Map.update!(:adapter, &adapter_name/1)
        |> Map.update!(:status, &Atom.to_string/1)
      end)

    {:ok, agents}
  end

  defp call_tool("start_agent", %{"initiative_id" => init_id, "dir" => dir, "adapter" => adapter}) do
    module = adapter_module(adapter)

    case Codrift.AgentSupervisor.start_agent(init_id, dir, module) do
      {:ok, pid} ->
        status =
          pid
          |> Codrift.AgentProcess.status()
          |> Map.update!(:adapter, &adapter_name/1)
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

    case Codrift.Initiative.Store.create(name, dirs) do
      {:ok, initiative} -> {:ok, Codrift.Initiative.to_map(initiative)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp call_tool("add_dir", %{"initiative_id" => id, "dir" => dir}) do
    expanded = Path.expand(dir)

    case Codrift.Initiative.Store.add_dir(id, expanded) do
      {:ok, initiative} -> {:ok, Codrift.Initiative.to_map(initiative)}
      {:error, :not_found} -> {:error, "initiative not found: #{id}"}
    end
  end

  defp call_tool("delete_initiative", %{"initiative_id" => id}) do
    case Codrift.Initiative.Store.delete(id) do
      :ok -> {:ok, %{"deleted" => id}}
      {:error, :not_found} -> {:error, "initiative not found: #{id}"}
    end
  end

  defp call_tool("set_initiative_status", %{"initiative_id" => id, "status" => status_str}) do
    valid = ~w(planning ongoing done archived)

    if status_str not in valid do
      {:error, "invalid status: #{status_str}. Must be one of: #{Enum.join(valid, ", ")}"}
    else
      status = String.to_existing_atom(status_str)

      case Codrift.Initiative.Store.set_status(id, status) do
        {:ok, initiative} -> {:ok, Codrift.Initiative.to_map(initiative)}
        {:error, :not_found} -> {:error, "initiative not found: #{id}"}
      end
    end
  end

  defp call_tool(name, _args), do: {:error, "unknown tool: #{name}"}

  defp dir_diffs(dir) do
    case Codrift.Diff.generate(dir) do
      {:ok, files} -> Enum.map(files, &Codrift.Diff.to_map/1)
      {:error, _} -> []
    end
  end

  defp adapter_module("claude"), do: Codrift.Agent.Adapters.Claude
  defp adapter_module("aider"), do: Codrift.Agent.Adapters.Aider
  defp adapter_module(name), do: raise("unknown adapter: #{name}")

  defp adapter_name(module) do
    module |> Module.split() |> List.last() |> String.downcase()
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
        "name" => "start_agent",
        "description" => "Start an AI coding agent in a directory",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "initiative_id" => %{"type" => "string"},
            "dir" => %{"type" => "string"},
            "adapter" => %{"type" => "string", "enum" => ["claude", "aider"]}
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
      }
    ]
  end
end
