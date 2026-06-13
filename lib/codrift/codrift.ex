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

  alias Codrift.Initiative.{DirEntry, Store}
  alias Codrift.MCP.Handler
  alias Codrift.OAuth
  alias Codrift.OAuth.Config, as: OAuthConfig

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Codrift.AgentRegistry},
      {Registry, keys: :unique, name: Codrift.ConductorRegistry},
      Codrift.SessionStore,
      Store,
      Codrift.AgentSupervisor,
      Codrift.ConductorSupervisor,
      {Task.Supervisor, name: Codrift.TaskSupervisor},
      Codrift.OAuth.StateStore,
      Codrift.Scheduler,
      {Bandit,
       [plug: __MODULE__, startup_log: false] ++
         Application.get_env(:codrift, :bandit_opts, [])}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Codrift.Supervisor)
  end

  get("/", fn _ -> "ok" end)

  get("/api/initiatives", fn _conn ->
    Enum.map(Store.list(), &Codrift.Initiative.to_map/1)
  end)

  get("/api/diff/:initiative_id", fn conn ->
    initiative_id = conn.params["initiative_id"]

    case Store.get(initiative_id) do
      {:ok, initiative} ->
        diffs =
          Enum.flat_map(initiative.dirs, fn entry ->
            effective = DirEntry.effective_path(entry)

            case Codrift.Diff.generate(effective) do
              {:ok, files} ->
                Enum.map(files, fn f -> Map.put(Codrift.Diff.to_map(f), "dir", entry.path) end)

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
        |> Map.update!(:adapter, &Codrift.Agent.adapter_name/1)
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

  # ── OAuth2 routes ────────────────────────────────────────────────────────────

  get("/oauth/start/:service", fn conn ->
    service = conn.params["service"]

    case OAuth.start_flow(service) do
      {:ok, %{flow: :pkce_browser, auth_url: url}} ->
        %{
          "flow" => "pkce_browser",
          "service" => service,
          "auth_url" => url,
          "redirect_uri" => OAuthConfig.redirect_uri(service),
          "message" => "Open auth_url in your browser to authorize #{service}"
        }

      {:ok, %{flow: :guided_token, instructions: instructions}} ->
        %{
          "flow" => "guided_token",
          "service" => service,
          "instructions" => instructions,
          "message" => "Follow the instructions to create an integration token"
        }

      {:error, reason} ->
        json(conn, 400, %{"error" => to_string(reason)})
    end
  end)

  get("/oauth/callback/:service", fn conn ->
    service = conn.params["service"]
    code = conn.params["code"]
    state = conn.params["state"]
    error = conn.params["error"]

    cond do
      error ->
        description = conn.params["error_description"] || error

        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(400, oauth_error_html(service, description))

      is_nil(code) or is_nil(state) ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(400, oauth_error_html(service, "Missing code or state parameter"))

      true ->
        case OAuth.handle_callback(service, code, state) do
          {:ok, _service} ->
            conn
            |> Plug.Conn.put_resp_content_type("text/html")
            |> Plug.Conn.send_resp(200, oauth_success_html(service))

          {:error, reason} ->
            conn
            |> Plug.Conn.put_resp_content_type("text/html")
            |> Plug.Conn.send_resp(400, oauth_error_html(service, to_string(reason)))
        end
    end
  end)

  get("/oauth/status", fn _conn ->
    all_services = OAuthConfig.supported_services()

    status =
      Map.new(all_services, fn service ->
        {service, %{"connected" => OAuth.connected?(service)}}
      end)

    %{"services" => status}
  end)

  defp oauth_success_html(service) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>Codrift — Connected</title>
      <style>
        body { font-family: system-ui, sans-serif; max-width: 480px; margin: 80px auto; padding: 0 16px; color: #1a1a1a; }
        h1 { font-size: 1.4rem; margin-bottom: 0.5rem; }
        .service { font-weight: 600; text-transform: capitalize; }
        p { color: #555; line-height: 1.5; }
        .ok { color: #16a34a; font-size: 2rem; }
      </style>
    </head>
    <body>
      <p class="ok">&#10003;</p>
      <h1>Connected to <span class="service">#{service}</span></h1>
      <p>Codrift now has access to your #{service} account. You can close this window.</p>
      <p>Run <code>codrift integration list #{service}</code> to see your items.</p>
    </body>
    </html>
    """
  end

  defp oauth_error_html(service, reason) do
    safe_reason = html_escape(reason)

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>Codrift — Authorization failed</title>
      <style>
        body { font-family: system-ui, sans-serif; max-width: 480px; margin: 80px auto; padding: 0 16px; color: #1a1a1a; }
        h1 { font-size: 1.4rem; margin-bottom: 0.5rem; }
        p { color: #555; line-height: 1.5; }
        .err { color: #dc2626; font-size: 2rem; }
        .reason { font-family: monospace; background: #f5f5f5; padding: 8px 12px; border-radius: 4px; }
      </style>
    </head>
    <body>
      <p class="err">&#10007;</p>
      <h1>Authorization failed for #{service}</h1>
      <p class="reason">#{safe_reason}</p>
      <p>Try running <code>codrift integration auth #{service}</code> again.</p>
    </body>
    </html>
    """
  end

  defp html_escape(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  # ── MCP routes ───────────────────────────────────────────────────────────────

  post("/mcp", fn conn ->
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Handler.dispatch(conn.body_params))
  end)

  sse("/mcp/sse", fn
    :join, _socket ->
      {:reply, %{event: "endpoint", data: "/mcp"}}

    {:close, _reason}, _socket ->
      :ok
  end)

  unmatched(fn _ -> "not found" end)
end
