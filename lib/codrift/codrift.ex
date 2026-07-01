defmodule Codrift do
  @moduledoc """
  Application entry point and HTTP router.

  Starts the supervision tree (Registry, Initiative.Store, AgentSupervisor,
  ConductorSupervisor, Bandit) and declares all HTTP/SSE routes.

  ## MCP server

  Exposes a Model Context Protocol server via HTTP+SSE transport:
    - `POST /mcp`     – JSON-RPC requests from MCP clients
    - `GET  /mcp/sse` – SSE stream for server-initiated notifications

  Run `mix codrift.mcp.install` to register the server with Claude Code.

  ## SSE initiative stream

  `GET /events/initiative/:id` streams events for a single initiative:

    - `connected`               – emitted on join with agent count
    - `output`                  – raw agent output chunk
    - `stopped`                 – agent exited with a code
    - `conductor_output`        – output chunk from a conductor-managed agent
    - `conductor_agent_ready`   – conductor agent became idle
    - `conductor_agent_stopped` – conductor agent exited
  """

  use Francis

  alias Codrift.Initiative.{DirEntry, Store}
  alias Codrift.MCP.Handler
  alias Codrift.OAuth
  alias Codrift.OAuth.Config, as: OAuthConfig

  @impl true
  def start(_type, _args) do
    if System.get_env("RELEASE_NAME") == "desktop" do
      # When launched as the Tauri desktop app, the process inherits macOS's
      # minimal launchd PATH (no ~/.local/bin, mise shims, homebrew…), so agent
      # CLIs like `claude` can't be found. Restore the user's login-shell PATH.
      ensure_login_path()
      # The sidecar's stdout is a pipe Tauri reads. If Tauri dies (crash /
      # force-quit) that pipe breaks, and continuing to log to it destabilises the
      # node's IO — which was preventing the heartbeat-loss shutdown from running
      # (the manager would restart instead of stopping). Log to a file instead so
      # a dead GUI can never wedge the backend's own shutdown path.
      redirect_logs_to_file()
    end

    base = [
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

    # Codrift.ShutdownManager System.stop/0s the app if it stops receiving the
    # Tauri heartbeat — only safe when actually launched as the desktop sidecar
    # (RELEASE_NAME=desktop). Gated so `mix codrift.tui`/`mix run` don't get
    # killed ~1.5s after boot. Placed last (after Bandit) so it can use
    # Codrift.TaskSupervisor and its timeout baseline starts near port-up, and it
    # only enforces the timeout after the first heartbeat (see its moduledoc).
    children =
      if System.get_env("RELEASE_NAME") == "desktop",
        do: base ++ [Codrift.ShutdownManager],
        else: base

    Supervisor.start_link(children, strategy: :one_for_one, name: Codrift.Supervisor)
  end

  # Merges the user's login-shell PATH into the running env so spawned agent
  # CLIs resolve. Best-effort: failures leave the existing PATH untouched.
  defp ensure_login_path do
    shell = System.get_env("SHELL") || "/bin/zsh"

    with {out, 0} <-
           System.cmd(shell, ["-lic", "echo CODRIFT_PATH=$PATH"], stderr_to_stdout: false),
         [_, login_path] <- Regex.run(~r/CODRIFT_PATH=(.+)/, out) do
      merged =
        (String.split(login_path, ":") ++ String.split(System.get_env("PATH") || "", ":"))
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.join(":")

      System.put_env("PATH", merged)
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  # Swap the console logger (which writes to the Tauri-owned stdout pipe) for a
  # file handler, so a dead GUI's broken pipe can't wedge the backend. Logs land
  # in <tmp>/codrift_desktop.log. Best-effort: keep the default handler on failure.
  defp redirect_logs_to_file do
    path = Path.join(System.tmp_dir!(), "codrift_desktop.log")

    :ok =
      :logger.add_handler(:codrift_file, :logger_std_h, %{
        config: %{type: {:file, String.to_charlist(path)}},
        formatter: Logger.Formatter.new()
      })

    :logger.remove_handler(:default)
    :ok
  rescue
    _ -> :ok
  end

  get("/", fn _ -> "ok" end)

  # Cheap liveness probe the web UI polls to detect (and recover from) a dropped
  # server — kept tiny so reconnect polling is effectively free.
  get("/api/health", fn _ -> %{ok: true} end)

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

  # Recent buffered output for a single agent, oldest-first. Used by web
  # terminals to replay scrollback before live bytes start arriving over SSE.
  get("/api/agent/:id/output", fn conn ->
    n =
      case Integer.parse(conn.params["n"] || "200") do
        {v, _} when v > 0 -> min(v, 1000)
        _ -> 200
      end

    case Codrift.AgentSupervisor.find_agent(conn.params["id"]) do
      {:ok, pid} ->
        # Base64 so binary/partial-UTF-8 PTY bytes survive JSON encoding.
        %{"output" => Enum.map(Codrift.AgentProcess.recent_output(pid, n), &Base.encode64/1)}

      {:error, :not_found} ->
        json(conn, 404, %{"error" => "agent not found"})
    end
  end)

  # Generic operation endpoint backing the web UI. Delegates to `Codrift.Core`,
  # the same layer the MCP server uses, so every product capability is reachable
  # from one route. Body: `{"name": "<op>", "args": {...}}`.
  post("/api/rpc", fn conn ->
    name = conn.body_params["name"]
    args = conn.body_params["args"] || %{}

    try do
      case Codrift.Core.call(name, args) do
        {:ok, result} -> %{"ok" => result}
        {:error, msg} -> json(conn, 422, %{"error" => msg})
      end
    rescue
      e -> json(conn, 400, %{"error" => Exception.message(e)})
    end
  end)

  # Bidirectional input channel for a single agent's PTY. Output flows the
  # other way over the initiative SSE stream (`/events/initiative/:id`).
  #
  # Client → server JSON frames:
  #   {"t":"d","d":"<bytes>"}       raw terminal data / keystrokes → send_raw
  #   {"t":"r","cols":N,"rows":M}   terminal resize → PTY winsz
  #
  # The handler body is inlined: `ws/3` compiles it into a separate generated
  # module, so it can only call public functions (not `Codrift` privates).
  ws("/ws/agent/:agent_id", fn
    :join, _socket ->
      :noreply

    {:received, frame}, socket ->
      with {:ok, pid} <- Codrift.AgentSupervisor.find_agent(socket.params["agent_id"]),
           {:ok, msg} <- JSON.decode(frame) do
        case msg do
          %{"t" => "d", "d" => data} when is_binary(data) ->
            Codrift.AgentProcess.send_raw(pid, data)

          %{"t" => "r", "cols" => cols, "rows" => rows}
          when is_integer(cols) and is_integer(rows) ->
            Codrift.AgentProcess.resize(pid, cols, rows)

          _ ->
            :ok
        end
      end

      :noreply

    {:close, _reason}, _socket ->
      :ok
  end)

  sse("/events/initiative/:id", fn
    :join, socket ->
      initiative_id = socket.params["id"]
      agents = Codrift.AgentSupervisor.list_agents_for_initiative(initiative_id)
      Enum.each(agents, &Codrift.AgentProcess.subscribe(&1, self()))

      case Codrift.ConductorSupervisor.find_conductor(initiative_id) do
        {:ok, conductor_pid} -> Codrift.Conductor.subscribe(conductor_pid, self())
        {:error, :not_found} -> :ok
      end

      {:reply,
       %{event: "connected", data: %{initiative_id: initiative_id, agent_count: length(agents)}}}

    {:received, {:agent_output, agent_id, data}}, _socket ->
      {:reply, %{event: "output", data: %{agent_id: agent_id, content: Base.encode64(data)}}}

    {:received, {:agent_stopped, agent_id, code}}, _socket ->
      {:reply, %{event: "stopped", data: %{agent_id: agent_id, exit_code: code}}}

    {:received, {:conductor_output, initiative_id, agent_id, data}}, _socket ->
      {:reply,
       %{
         event: "conductor_output",
         data: %{initiative_id: initiative_id, agent_id: agent_id, content: Base.encode64(data)}
       }}

    {:received, {:conductor_agent_ready, initiative_id, agent_id}}, _socket ->
      {:reply,
       %{
         event: "conductor_agent_ready",
         data: %{initiative_id: initiative_id, agent_id: agent_id}
       }}

    {:received, {:conductor_agent_stopped, initiative_id, agent_id, code}}, _socket ->
      {:reply,
       %{
         event: "conductor_agent_stopped",
         data: %{initiative_id: initiative_id, agent_id: agent_id, exit_code: code}
       }}

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

      {:ok,
       %{
         flow: :device_flow,
         user_code: user_code,
         verification_uri: verification_uri,
         device_code: device_code,
         expires_in: expires_in,
         interval: interval
       }} ->
        expires_at = System.os_time(:second) + expires_in
        OAuth.poll_device_auth(nil, service, device_code, expires_at, interval, nil)

        %{
          "flow" => "device_flow",
          "service" => service,
          "user_code" => user_code,
          "verification_uri" => verification_uri,
          "message" => "Visit #{verification_uri} and enter code #{user_code}"
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
