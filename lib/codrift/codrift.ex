defmodule Codrift do
  @moduledoc """
  Application entry point and HTTP router.

  Starts the supervision tree (Registry, Initiative.Store, AgentSupervisor,
  ConductorSupervisor, Freshness, Bandit) and declares all HTTP routes.

  ## MCP server

  Exposes a Model Context Protocol server over both HTTP transports:

    - `POST /mcp` – Streamable HTTP (MCP 2025-03-26). The JSON-RPC response is
      the POST body. This is what `codrift mcp install` registers.
    - `GET /mcp/sse` – HTTP+SSE (MCP 2024-11-05), for clients that only speak
      the older transport. The stream names a session, and responses to
      `POST /mcp?sessionId=…` come back down it. See `Codrift.MCP.SSESession`.

  Run `mix codrift.mcp.install` to register the server with Claude Code.

  ## Live WebSocket

  `ws /ws` carries the live surface both ways for the whole workspace: agent
  output and status out, keystrokes and resizes in. See `Codrift.Web.EventRelay`
  for the frame shapes.
  """

  use Francis

  require Logger

  alias Codrift.Initiative.{DirEntry, Store}
  alias Codrift.MCP.Handler
  alias Codrift.MCP.SSESession
  alias Codrift.OAuth
  alias Codrift.OAuth.Config, as: OAuthConfig

  # Reject browser-borne cross-origin / DNS-rebinding requests before any route
  # runs. See Codrift.Plugs.LocalGuard.
  plug(Codrift.Plugs.LocalGuard)

  @impl true
  def start(_type, _args) do
    if desktop_sidecar?() do
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
      # A second sidecar can never share the port, and failing here (rather than
      # deep inside Bandit's start) is what lets the Rust shell tell the user why.
      warn_if_port_taken()
    end

    base = [
      {Registry, keys: :unique, name: Codrift.AgentRegistry},
      {Registry, keys: :unique, name: Codrift.ConductorRegistry},
      {Registry, keys: :duplicate, name: Codrift.AgentWatchers},
      SSESession,
      Codrift.SessionStore,
      Store,
      Codrift.AgentSupervisor,
      Codrift.ConductorSupervisor,
      {Task.Supervisor, name: Codrift.TaskSupervisor},
      Codrift.OAuth.StateStore,
      Codrift.Scheduler,
      Codrift.Freshness,
      Codrift.Updater.Runner,
      {Bandit,
       [plug: __MODULE__, startup_log: false] ++
         Application.get_env(:codrift, :bandit_opts, [])}
    ]

    # Codrift.ShutdownManager System.stop/0s the app if it stops receiving the
    # Tauri heartbeat — only safe when actually launched as the desktop sidecar.
    # Gated so `mix run`/plain server boots don't get killed ~1.5s after boot.
    # Placed last (after Bandit) so it can use Codrift.TaskSupervisor and its
    # timeout baseline starts near port-up, and it only enforces the timeout
    # after the first heartbeat (see its moduledoc).
    children =
      if desktop_sidecar?(),
        do: base ++ [Codrift.ShutdownManager],
        else: base

    Supervisor.start_link(children, strategy: :one_for_one, name: Codrift.Supervisor)
  end

  # True when running as the Tauri desktop sidecar.
  #
  # Two spellings because the sidecar is launched two different ways. A plain
  # mix release (`mix ex_tauri.dev`, or `sidecar: :release`) boots through
  # `bin/desktop`, which exports RELEASE_NAME. The *shipped* build is
  # Burrito-wrapped, and Burrito's launcher execve's `erl` directly with a
  # hand-built env map — it sets RELEASE_ROOT and __BURRITO but never
  # RELEASE_NAME (see deps/burrito/src/erlang_launcher.zig). Checking only
  # RELEASE_NAME therefore held in dev and silently failed in every released
  # app: no login PATH (so `claude` and friends were never found), no file
  # logging, no port check and no ShutdownManager.
  defp desktop_sidecar? do
    System.get_env("RELEASE_NAME") == "desktop" or System.get_env("__BURRITO") == "1"
  end

  # Merges the user's login-shell PATH into the running env so spawned agent
  # CLIs resolve. Best-effort: failures leave the existing PATH untouched.
  defp ensure_login_path do
    shell = System.get_env("SHELL") || "/bin/zsh"

    with {out, 0} <- login_shell_path(shell),
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

  # `-l` sources the login files, `-i` the interactive ones — between them they
  # cover where version managers (mise, asdf, nvm) actually put their shims. An
  # interactive shell with no TTY is also exactly the shape that can block
  # forever on a dotfile waiting for input, and this runs before the supervision
  # tree, so a wedged shell would hang the whole app at boot. Cap it and carry on
  # with the launchd PATH instead; the orphan exits on its own.
  defp login_shell_path(shell) do
    task =
      Task.async(fn ->
        System.cmd(shell, ["-lic", "echo CODRIFT_PATH=$PATH"], stderr_to_stdout: false)
      end)

    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> :timeout
    end
  end

  # Log a precise reason before Bandit's own `:eaddrinuse` crash, which reads as a
  # generic supervisor failure. The desktop log is the only trace a packaged app
  # leaves, so it has to name the actual problem.
  defp warn_if_port_taken do
    port = Keyword.get(Application.get_env(:codrift, :bandit_opts, []), :port, 43_117)

    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

        Logger.error(
          "[Codrift] port #{port} is already in use — another Codrift backend is running. " <>
            "This sidecar will exit; quit the other instance and reopen Codrift."
        )

      {:error, _} ->
        :ok
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
  #
  # `instance` echoes CODRIFT_INSTANCE_TOKEN, which the Tauri shell sets on the
  # sidecar it spawns. That is how the shell recognises *its own* backend rather
  # than adopting whatever else happens to hold the port (see src-tauri/src/main.rs).
  get("/api/health", fn _ ->
    %{ok: true, instance: System.get_env("CODRIFT_INSTANCE_TOKEN") || ""}
  end)

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

  # Recent buffered output for a single agent, oldest-first — terminal scrollback.
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
        # No live process — fall back to the durable transcript log so the
        # scrollback of stopped/crashed agents survives restarts.
        case Codrift.AgentLogs.tail(conn.params["id"]) do
          {:ok, data} -> %{"output" => [Base.encode64(data)], "source" => "log"}
          {:error, :not_found} -> json(conn, 404, %{"error" => "agent not found"})
        end
    end
  end)

  # Raw bytes for a previewable image inside one of the initiative's directories.
  #
  # The one read that is not an op on `/api/rpc`: `<img src>` issues a GET and
  # cannot POST a JSON body, and base64ing a multi-megabyte screenshot through
  # the RPC envelope to work around that would cost a third more bytes and skip
  # the browser's own image cache. Containment is the same as `read_file` —
  # `Codrift.Files.read_image_within/2` resolves symlinks and refuses anything
  # outside the directories this initiative holds — and the extension allowlist
  # keeps it from becoming a general "read any file as bytes" route.
  get("/api/file", fn conn -> serve_image(conn) end)

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

  # Client frames: {"t":"d",agent_id,d} keystrokes, {"t":"r",agent_id,cols,rows} resize.
  # Server frames come from Codrift.Web.EventRelay. The handler is compiled into
  # its own module, so it can only call public functions — and this module's
  # aliases do not reach it either, hence the fully-qualified calls below (and
  # the credo exemption on them: aliasing here fails to compile).
  #
  # max_frame_size covers a large paste (one frame); timeout must stay above two
  # heartbeat intervals, since an idle terminal only sends the browser's pongs.
  ws(
    "/ws",
    fn
      :join, _socket ->
        # credo:disable-for-lines:2 Credo.Check.Design.AliasUsage
        {:ok, _relay} = Codrift.Web.EventRelay.start_link()
        {:reply, %{event: "connected", agents: Codrift.Web.EventRelay.snapshot()}}

      {:received, frame}, _socket ->
        with {:ok, %{"agent_id" => agent_id} = msg} <- JSON.decode(frame),
             {:ok, pid} <- Codrift.AgentSupervisor.find_agent(agent_id) do
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
    end,
    max_frame_size: 4 * 1024 * 1024,
    heartbeat_interval: 30_000,
    timeout: 90_000
  )

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
    service = html_escape(service)

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
    service = html_escape(service)

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

  post("/mcp", fn conn -> mcp_post(conn) end)

  # Streamable HTTP has no server-initiated stream here and no session to tear
  # down, and the spec says to say so with 405 rather than to look like a
  # missing route. A client that probes `GET /mcp` should fall back to plain
  # request/response, not conclude the server is not there.
  get("/mcp", fn conn -> mcp_method_not_allowed(conn) end)
  delete("/mcp", fn conn -> mcp_method_not_allowed(conn) end)

  # HTTP+SSE (MCP 2024-11-05). The `endpoint` event has to name a *session*, not
  # a bare path: it is the only thing tying the client's later POSTs back to
  # this stream, and every JSON-RPC response it is waiting for arrives here.
  sse("/mcp/sse", fn
    :join, _socket ->
      # Fully qualified: `sse/2` compiles its handler into a generated module,
      # where this module's aliases are not in scope.
      # credo:disable-for-next-line Credo.Check.Design.AliasUsage
      {:reply, %{event: "endpoint", data: "/mcp?sessionId=#{Codrift.MCP.SSESession.open()}"}}

    {:received, {:mcp_message, body}}, _socket ->
      {:reply, %{event: "message", data: body}}

    {:close, _reason}, _socket ->
      :ok
  end)

  unmatched(fn _ -> "not found" end)

  # Two transports arrive on this one route, and which is in play is decided by
  # `sessionId`:
  #
  #   * absent  – Streamable HTTP (MCP 2025-03-26), what `codrift mcp install`
  #     registers. The response is the POST body.
  #   * present – HTTP+SSE (2024-11-05). The POST is only acknowledged; the
  #     response belongs on that session's stream. Answering in the body here
  #     would leave the client blocked on the stream until it timed out.
  defp serve_image(conn) do
    id = conn.params["initiative_id"] || ""
    path = conn.params["path"] || ""

    with {:ok, initiative} <- Store.get(id),
         allowed = image_roots(initiative),
         {:ok, mime, data} <- Codrift.Files.read_image_within(allowed, path) do
      conn
      |> Plug.Conn.put_resp_content_type(mime)
      # The editor writes over previewed files, so a stale cached copy would
      # show the old picture. Revalidation is cheap on loopback.
      |> Plug.Conn.put_resp_header("cache-control", "no-cache")
      |> Plug.Conn.send_resp(200, data)
    else
      {:error, :not_found} ->
        json(conn, 404, %{"error" => "initiative not found: #{id}"})

      {:error, :forbidden} ->
        json(conn, 403, %{"error" => "path is outside the initiative"})

      {:error, :not_an_image} ->
        json(conn, 415, %{"error" => "not a previewable image"})

      {:error, :too_large} ->
        json(conn, 413, %{"error" => "image is too large to preview"})

      {:error, :enoent} ->
        json(conn, 404, %{"error" => "no such file"})

      {:error, reason} ->
        json(conn, 422, %{"error" => "could not read image: #{inspect(reason)}"})
    end
  end

  # The initiative's own context folder counts as one of its directories here,
  # even though it is not in `dirs`. It is where agents drop screenshots and
  # where the context documents that reference them live, and
  # `list_context_files` already offers both — so leaving it out meant the
  # Context pane listing an image it then had no way to show.
  defp image_roots(initiative) do
    [Store.context_path(initiative.id) | Enum.map(initiative.dirs, &DirEntry.effective_path/1)]
  end

  defp mcp_post(conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    if Handler.notification?(conn.body_params) do
      # A notification gets no JSON-RPC response on either transport.
      Plug.Conn.send_resp(conn, 202, "")
    else
      mcp_reply(conn, conn.query_params["sessionId"], Handler.dispatch(conn.body_params))
    end
  end

  defp mcp_reply(conn, nil, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, body)
  end

  defp mcp_reply(conn, session_id, body) do
    case SSESession.deliver(session_id, body) do
      :ok -> Plug.Conn.send_resp(conn, 202, "")
      {:error, :no_session} -> Plug.Conn.send_resp(conn, 404, "Unknown MCP session")
    end
  end

  defp mcp_method_not_allowed(conn) do
    conn
    |> Plug.Conn.put_resp_header("allow", "POST")
    |> Plug.Conn.send_resp(405, "Method not allowed")
  end
end
