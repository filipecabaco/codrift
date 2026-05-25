defmodule Codrift do
  @moduledoc """
  Application entry point and HTTP router.

  Starts the supervision tree (Registry, Initiative.Store, AgentSupervisor, Bandit)
  and declares all HTTP/SSE routes.

  ## MCP server

  Exposes a Model Context Protocol server via HTTP+SSE transport:
    - `POST /mcp`     – JSON-RPC requests from MCP clients
    - `GET  /mcp/sse` – SSE stream for server-initiated notifications

  Run `mix codrift.mcp.install` to register the server with Claude Code.
  """

  use Francis

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Codrift.AgentRegistry},
      Codrift.Initiative.Store,
      Codrift.AgentSupervisor,
      {Task.Supervisor, name: Codrift.TaskSupervisor},
      {Bandit,
       [plug: __MODULE__, startup_log: false] ++
         Application.get_env(:codrift, :bandit_opts, [])}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Codrift.Supervisor)
  end

  get("/", fn _ -> "ok" end)

  get("/api/initiatives", fn _conn ->
    Enum.map(Codrift.Initiative.Store.list(), &Codrift.Initiative.to_map/1)
  end)

  get("/api/diff/:initiative_id", fn conn ->
    initiative_id = conn.params["initiative_id"]

    case Codrift.Initiative.Store.get(initiative_id) do
      {:ok, initiative} ->
        diffs =
          Enum.flat_map(initiative.dirs, fn dir ->
            case Codrift.Diff.generate(dir) do
              {:ok, files} ->
                Enum.map(files, fn f -> Map.put(Codrift.Diff.to_map(f), "dir", dir) end)

              {:error, _} ->
                []
            end
          end)

        %{"initiative_id" => initiative_id, "diffs" => diffs}

      {:error, :not_found} ->
        json(conn, 404, %{"error" => "initiative not found"})
    end
  end)

  get("/api/agent/:id", fn conn ->
    case Codrift.AgentSupervisor.find_agent(conn.params["id"]) do
      {:ok, pid} ->
        pid
        |> Codrift.AgentProcess.status()
        |> Map.update!(:adapter, fn m ->
          m |> Module.split() |> List.last() |> String.downcase()
        end)
        |> Map.update!(:status, &Atom.to_string/1)

      {:error, :not_found} ->
        json(conn, 404, %{"error" => "agent not found"})
    end
  end)

  sse("/events/initiative/:id", fn
    :join, socket ->
      initiative_id = socket.params["id"]
      agents = Codrift.AgentSupervisor.list_agents_for_initiative(initiative_id)
      Enum.each(agents, &Codrift.AgentProcess.subscribe(&1, self()))

      {:reply,
       %{event: "connected", data: %{initiative_id: initiative_id, agent_count: length(agents)}}}

    {:received, {:agent_output, agent_id, data}}, _socket ->
      {:reply, %{event: "output", data: %{agent_id: agent_id, content: data}}}

    {:received, {:agent_stopped, agent_id, code}}, _socket ->
      {:reply, %{event: "stopped", data: %{agent_id: agent_id, exit_code: code}}}

    {:received, _}, _socket ->
      :noreply

    {:close, _reason}, _socket ->
      :ok
  end)

  post("/mcp", fn conn ->
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Codrift.MCP.Handler.dispatch(conn.body_params))
  end)

  sse("/mcp/sse", fn
    :join, _socket ->
      {:reply, %{event: "endpoint", data: "/mcp"}}

    {:close, _reason}, _socket ->
      :ok
  end)

  unmatched(fn _ -> "not found" end)
end
